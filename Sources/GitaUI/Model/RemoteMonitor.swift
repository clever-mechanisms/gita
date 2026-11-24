import AppKit
import Foundation
import GitaCore
import Network

/// Dependencies for `RemoteMonitor`, injected in tests for fake clocks, jitter, network paths and fixture Git runs.
struct RemoteMonitorEnvironment {
    var now: () -> Date = Date.init
    var jitter: () -> Double = { Double.random(in: -1...1) }
    var staggerDelay: (Int) -> TimeInterval = { index in
        index == 0 ? 0 : Double.random(in: RemoteCheckPolicy.staggerRange)
    }
    var sleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
        if seconds > 0 { try await Task.sleep(for: .seconds(seconds)) }
    }
    var isLowPowerMode: () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled }
    var checkRemote:
        @Sendable (GitService, String, [String: GitBranchUpstream], [GitReference], String?, Date) async throws ->
            RemoteDelta = { service, remote, upstreams, references, branch, now in
                try await service.checkRemote(
                    remote, upstreams: upstreams, references: references, currentBranch: branch, now: now)
            }
    var backgroundFetch: @Sendable (GitService, String) async throws -> Void = { service, remote in
        try await service.backgroundFetch(remote: remote)
    }
    var startsSystemMonitors = true
}

struct QueuedRemoteCheck {
    let id: String
    let allowAutoFetch: Bool
    let allowStagger: Bool
}

@MainActor
struct RemoteEntry {
    let root: URL
    var service: GitService
    var defaults: UserDefaults
    var snapshot: RepositorySnapshot?
    var phase = RemoteCheckState.Phase.off
    var last: RemoteDelta?
    var state: RemoteCheckState { RemoteCheckState(phase: phase, last: last) }
    var lastFetchAt: Date?
    var failures = 0
    var pausedAuthRemotes: Set<String> = []
    var pendingManualCheck = false
    var observers: [ObjectIdentifier: WeakObserverBox] = [:]

    var isFrontTab: Bool {
        observers.values.contains { ($0.model?.isActiveRepository == true) && ($0.model?.isWindowVisible == true) }
    }

    var isAnyActiveTab: Bool {
        observers.values.contains { $0.model?.isActiveRepository == true }
    }

    var isMutating: Bool {
        observers.values.contains { $0.model?.isMutating == true }
    }

    mutating func pruneDeadObservers() {
        observers = observers.filter { $0.value.model != nil }
    }
}

struct WeakObserverBox {
    weak var model: AppModel?
}

/// Process-wide background remote awareness coordinator (`ls-remote` Tier 1 checks and opt-in Tier 2 atomic
/// auto-fetch), gated by `NWPathMonitor`, Low Power Mode, concurrency cap 2, stagger, and exponential backoff.
@MainActor
final class RemoteMonitor {
    static let shared = RemoteMonitor()
    private static let tickInterval: TimeInterval = 30

    let environment: RemoteMonitorEnvironment
    private(set) var networkStatus: RemoteNetworkStatus
    var entries: [String: RemoteEntry] = [:]
    var modelRoots: [ObjectIdentifier: String] = [:]
    var queue: [QueuedRemoteCheck] = []
    var inFlight: [String: UUID] = [:]
    var staggerIndex = 0
    private var pathMonitor: NWPathMonitor?
    private let networkQueue = DispatchQueue(label: "dev.clevermechanisms.Gita.remoteMonitor.network")
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    init(environment: RemoteMonitorEnvironment = RemoteMonitorEnvironment()) {
        self.environment = environment
        self.networkStatus = RemoteNetworkStatus(
            isSatisfied: true, isConstrained: false, isExpensive: false,
            isLowPowerMode: environment.isLowPowerMode())
        if environment.startsSystemMonitors { startSystemMonitors() }
    }

    isolated deinit {
        timer?.invalidate()
        pathMonitor?.cancel()
        for token in observers { NotificationCenter.default.removeObserver(token) }
        for entry in entries.values { entry.state.task?.cancel() }
    }

    // MARK: Registration & State

    func register(
        model: AppModel, root: URL, service: GitService, snapshot: RepositorySnapshot?, defaults: UserDefaults
    ) {
        let standardized = root.standardizedFileURL
        let id = standardized.path
        let modelID = ObjectIdentifier(model)
        if let previousID = modelRoots[modelID], previousID != id {
            removeObserver(modelID: modelID, from: previousID)
        }
        modelRoots[modelID] = id
        var entry = entries[id] ?? RemoteEntry(root: standardized, service: service, defaults: defaults)
        let previousURLs = entry.snapshot?.remoteURLs
        entry.service = service
        entry.defaults = defaults
        entry.snapshot = snapshot ?? entry.snapshot
        entry.observers[modelID] = WeakObserverBox(model: model)
        entry.pruneDeadObservers()
        if let snapshot {
            reconcileSnapshotChanges(for: &entry, previousURLs: previousURLs ?? [:], snapshot: snapshot)
        }
        store(entry, id: id)
        reconcileEntry(id: id)
    }

    func unregister(model: AppModel) {
        let modelID = ObjectIdentifier(model)
        guard let id = modelRoots.removeValue(forKey: modelID) else { return }
        removeObserver(modelID: modelID, from: id)
    }

    func state(for root: URL?) -> RemoteCheckState {
        guard let id = root?.standardizedFileURL.path else { return RemoteCheckState() }
        return entries[id]?.state ?? RemoteCheckState()
    }

    func statusSummary(for root: URL?, now: Date? = nil) -> String {
        state(for: root).statusSummary(now: now ?? environment.now())
    }

    func statusLine(for roots: [URL], now: Date? = nil) -> String {
        let reference = now ?? environment.now()
        return roots.compactMap { root -> String? in
            let entryState = state(for: root)
            guard case .off = entryState.phase else {
                return "\(root.lastPathComponent) \(entryState.statusSummary(now: reference))"
            }
            return nil
        }.joined(separator: " · ")
    }

    // MARK: Triggers & Lifecycle Events

    func checkNow(for root: URL?, allowAutoFetch: Bool = true) {
        guard let id = root?.standardizedFileURL.path, var entry = entries[id] else { return }
        let settings = RemoteUpdateSettings.load(from: entry.defaults)
        guard settings.checkEnabled, networkStatus.isSatisfied else { return }
        if entry.state.isBusy {
            entry.pendingManualCheck = true
            entries[id] = entry
            return
        }
        enqueue(id: id, allowAutoFetch: allowAutoFetch, allowStagger: false)
        drainQueue()
    }

    func becameFront(for root: URL?) {
        guard let id = root?.standardizedFileURL.path, let entry = entries[id] else { return }
        let settings = RemoteUpdateSettings.load(from: entry.defaults)
        let action = RemoteCheckPolicy.onBecomingFront(
            settings: settings, network: networkStatus, lastCheck: entry.last?.checkedAt,
            lastFetch: entry.lastFetchAt, now: environment.now())
        guard case .check(let allowFetch) = action else { return }
        checkNow(for: root, allowAutoFetch: allowFetch)
    }

    func cancelBackgroundFetch(for root: URL?) {
        guard let id = root?.standardizedFileURL.path, var entry = entries[id], entry.state.isBusy else { return }
        entry.state.cancel()
        let cadence = RemoteUpdateSettings.load(from: entry.defaults).cadence.interval
        let next = environment.now().addingTimeInterval(cadence)
        entry.phase = .waiting(next: next)
        inFlight.removeValue(forKey: id)
        store(entry, id: id)
        drainQueue()
    }

    func didCompleteManualSync(for root: URL?, reenableAuth: Bool) {
        guard let id = root?.standardizedFileURL.path, var entry = entries[id] else { return }
        let now = environment.now()
        entry.failures = 0
        if reenableAuth {
            entry.pausedAuthRemotes.removeAll()
            entry.lastFetchAt = now
        }
        if case .backingOff(_, let reason) = entry.phase,
            reason != .unsupportedURL, reason != .authenticationRequired || reenableAuth
        {
            let cadence = RemoteUpdateSettings.load(from: entry.defaults).cadence.interval
            entry.phase = .waiting(next: now.addingTimeInterval(cadence))
        }
        store(entry, id: id)
    }

    func updateNetworkStatus(_ next: RemoteNetworkStatus) {
        let wasSatisfied = networkStatus.isSatisfied
        networkStatus = next
        if !next.isSatisfied {
            queue.removeAll()
            for id in Array(entries.keys) { transitionToOffline(id: id) }
        } else if !wasSatisfied {
            for id in Array(entries.keys) { restoreFromOffline(id: id) }
            drainQueue()
        }
    }

    func tick() {
        let current = environment.now()
        for id in entries.keys.sorted() {
            guard var entry = entries[id] else { continue }
            entry.pruneDeadObservers()
            if entry.observers.isEmpty {
                removeEntry(id: id)
                continue
            }
            entries[id] = entry
            let settings = RemoteUpdateSettings.load(from: entry.defaults)
            let isFront = entry.isAnyActiveTab
            if RemoteCheckPolicy.isScheduledCheckDue(
                state: entry.phase, settings: settings, network: networkStatus, isFrontTab: isFront, now: current)
            {
                enqueue(id: id, allowAutoFetch: true, allowStagger: true)
            }
        }
        drainQueue()
    }

    // MARK: System Monitors & Entry Reconciliation

    private func startSystemMonitors() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let isSatisfied = path.status == .satisfied
            let isConstrained = path.isConstrained
            let isExpensive = path.isExpensive
            Task { @MainActor [weak self] in
                guard let self else { return }
                let status = RemoteNetworkStatus(
                    isSatisfied: isSatisfied, isConstrained: isConstrained,
                    isExpensive: isExpensive, isLowPowerMode: self.environment.isLowPowerMode())
                self.updateNetworkStatus(status)
            }
        }
        monitor.start(queue: networkQueue)
        pathMonitor = monitor
        registerNotificationObservers()
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func registerNotificationObservers() {
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    var status = self.networkStatus
                    status.isLowPowerMode = self.environment.isLowPowerMode()
                    self.updateNetworkStatus(status)
                }
            })
        observers.append(
            center.addObserver(forName: .gitaPreferenceChanged, object: nil, queue: .main) { [weak self] note in
                let pref = Preference(changed: note)
                MainActor.assumeIsolated {
                    guard let pref, Preference.remoteUpdateKeys.contains(pref) else { return }
                    self?.preferencesChanged()
                }
            })
        for name in [NSApplication.didBecomeActiveNotification, NSWindow.didBecomeMainNotification] {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.frontWindowChanged() }
                })
        }
    }

    private func preferencesChanged() {
        for id in Array(entries.keys) {
            let wasOff: Bool =
                if case .off = entries[id]?.phase { true } else { false }
            reconcileEntry(id: id)
            if wasOff, let entry = entries[id], case .waiting = entry.phase {
                let settings = RemoteUpdateSettings.load(from: entry.defaults)
                if settings.scope == .allOpenTabs || entry.isAnyActiveTab {
                    enqueue(id: id, allowAutoFetch: true, allowStagger: true)
                }
            }
        }
        drainQueue()
    }

    private func frontWindowChanged() {
        for entry in entries.values where entry.isFrontTab { becameFront(for: entry.root) }
    }

    private func reconcileSnapshotChanges(
        for entry: inout RemoteEntry, previousURLs: [String: String], snapshot: RepositorySnapshot
    ) {
        if !previousURLs.isEmpty, previousURLs != snapshot.remoteURLs {
            for (name, url) in snapshot.remoteURLs where previousURLs[name] != url {
                entry.pausedAuthRemotes.remove(name)
            }
            if case .backingOff(_, let reason) = entry.phase,
                reason == .unsupportedURL || reason == .authenticationRequired
            {
                entry.phase = .waiting(next: environment.now())
            }
        }
        entry.last?.reconciling(references: snapshot.references)
    }

    private func reconcileEntry(id: String) {
        guard var entry = entries[id] else { return }
        let settings = RemoteUpdateSettings.load(from: entry.defaults)
        if !settings.checkEnabled || entry.snapshot?.remoteURLs.isEmpty == true {
            entry.state.cancel()
            inFlight.removeValue(forKey: id)
            entry.phase = .off
            entry.last = nil
        } else if !networkStatus.isSatisfied {
            entry.phase = .offline
        } else if case .off = entry.phase {
            entry.phase = .waiting(next: environment.now())
        } else {
            return
        }
        store(entry, id: id)
    }

    private func removeObserver(modelID: ObjectIdentifier, from id: String) {
        guard var entry = entries[id] else { return }
        entry.observers[modelID] = nil
        entry.pruneDeadObservers()
        if entry.observers.isEmpty {
            removeEntry(id: id)
        } else {
            entries[id] = entry
        }
    }

    private func removeEntry(id: String) {
        entries[id]?.state.cancel()
        entries[id] = nil
        queue.removeAll { $0.id == id }
        inFlight.removeValue(forKey: id)
    }

    private func transitionToOffline(id: String) {
        guard var entry = entries[id] else { return }
        if case .off = entry.phase { return }
        entry.state.cancel()
        inFlight.removeValue(forKey: id)
        entry.phase = .offline
        store(entry, id: id)
    }

    private func restoreFromOffline(id: String) {
        guard var entry = entries[id], case .offline = entry.phase else { return }
        let settings = RemoteUpdateSettings.load(from: entry.defaults)
        guard settings.checkEnabled else {
            entry.phase = .off
            entry.last = nil
            store(entry, id: id)
            return
        }
        entry.phase = .waiting(next: environment.now())
        store(entry, id: id)
        let active = entry.isAnyActiveTab
        if settings.scope == .allOpenTabs || active {
            enqueue(id: id, allowAutoFetch: true, allowStagger: true)
        }
    }

    /// Publish the complete entry before synchronous observers query the monitor or update it again.
    func store(_ entry: RemoteEntry, id: String) {
        let previous = entries.updateValue(entry, forKey: id)?.state ?? RemoteCheckState()
        for box in entry.observers.values {
            box.model?.remoteCheckStateChanged(entry.state, previous: previous)
        }
    }

    func notifyAutoFetched(entry: RemoteEntry) {
        for box in entry.observers.values {
            box.model?.remoteAutoFetchCompleted()
        }
    }
}
