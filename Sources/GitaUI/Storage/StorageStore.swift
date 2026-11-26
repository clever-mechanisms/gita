import Foundation
import GitaCore

struct WorkspaceScanFailure: Equatable {
    let root: URL
    let message: String
}

enum WorkspaceStorageScanState: Equatable {
    case idle
    case scanning(completed: Int, total: Int, partial: [RepositoryStorageReport], failures: [WorkspaceScanFailure])
    case loaded(reports: [RepositoryStorageReport], failures: [WorkspaceScanFailure])
    case failed(String)
}

enum RepositoryHealthLoadState: Equatable {
    case idle, loading
    case loaded(RepositoryHealthSnapshot)
    case failed(String)
}

enum HealthActionState: Equatable {
    case idle
    case running(String)
    case succeeded(String)
    case failed(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

@MainActor
final class StorageStore {
    typealias Scan = @Sendable (URL, @escaping StorageProgressHandler) async throws -> RepositoryStorageReport
    static let defaultCacheTTL: TimeInterval = 600
    private let ttl: TimeInterval
    private let now: () -> Date
    private let scan: Scan
    let health: RepositoryHealthService
    private var states = [String: StorageScanState]()
    private var scans = [String: Task<Void, Never>]()
    private var aliases = [String: String]()
    private var workspaceTask: Task<Void, Never>?
    private(set) var workspaceState = WorkspaceStorageScanState.idle
    var healthStates = [String: RepositoryHealthLoadState]()
    var healthTasks = [String: Task<Void, Never>]()
    var actions = [String: HealthActionState]()
    private var observers = [UUID: () -> Void]()

    init(
        cacheTTL: TimeInterval = defaultCacheTTL, now: @escaping () -> Date = Date.init,
        health: RepositoryHealthService = RepositoryHealthService(),
        scan: @escaping Scan = { try await StorageScanner().scan(repositoryRoot: $0, progress: $1) }
    ) {
        ttl = cacheTTL
        self.now = now
        self.health = health
        self.scan = scan
    }

    func addObserver(_ observer: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    func removeObserver(_ id: UUID) { observers[id] = nil }
    func notify() { for observer in Array(observers.values) { observer() } }

    func canonicalPath(_ root: URL) -> String {
        root.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func key(_ root: URL) -> String {
        let path = canonicalPath(root)
        return aliases[path] ?? path
    }

    func state(for root: URL) -> StorageScanState { states[key(root)] ?? .idle }

    @discardableResult
    func scanRepository(_ root: URL, refresh: Bool = false) -> Task<Void, Never>? {
        let key = key(root)
        if let task = scans[key] {
            if !refresh { return task }
            task.cancel()
        }
        if !refresh, case .loaded(_, let cachedAt) = states[key], now().timeIntervalSince(cachedAt) < ttl {
            notify()
            return nil
        }
        let id = UUID()
        states[key] = .scanning(id: id, progress: StorageScanProgress(), partial: nil)
        let task = Task {
            do {
                let report = try await scan(root) { progress, partial in
                    Task { @MainActor in self.update(key, id: id, progress: progress, partial: partial) }
                }
                try Task.checkCancellation()
                guard states[key]?.scanID == id else { return }
                states[key] = .loaded(report, cachedAt: now())
                for path in [report.mainRoot] + report.checkouts.map(\.path) where states[path.path] == nil {
                    aliases[path.path] = key
                }
            } catch {
                guard states[key]?.scanID == id else { return }
                states[key] = Task.isCancelled ? .idle : .failed(error.localizedDescription)
            }
            scans[key] = nil
            notify()
        }
        scans[key] = task
        notify()
        return task
    }

    private func update(_ key: String, id: UUID, progress: StorageScanProgress, partial: RepositoryStorageReport?) {
        guard case .scanning(id, let previous, let existing) = states[key],
            previous.scannedCheckouts <= progress.scannedCheckouts, previous.bytesCounted <= progress.bytesCounted
        else { return }
        states[key] = .scanning(id: id, progress: progress, partial: partial ?? existing)
        notify()
    }

    @discardableResult
    func scanWorkspace(_ roots: [URL], refresh: Bool = false) -> Task<Void, Never> {
        workspaceTask?.cancel()
        var seen = Set<String>()
        let roots = roots.filter { seen.insert(key($0)).inserted }
        workspaceState = .scanning(completed: 0, total: roots.count, partial: [], failures: [])
        let task = Task {
            var reports = [RepositoryStorageReport]()
            var failures = [WorkspaceScanFailure]()
            for (index, root) in roots.enumerated() {
                guard !Task.isCancelled else { return }
                await scanRepository(root, refresh: refresh)?.value
                guard !Task.isCancelled else { return }
                if let report = state(for: root).report {
                    if !reports.contains(where: { $0.id == report.id }) { reports.append(report) }
                } else {
                    let message = state(for: root).errorMessage ?? String(localized: "Scan interrupted.")
                    failures.append(WorkspaceScanFailure(root: root, message: message))
                }
                workspaceState = .scanning(
                    completed: index + 1, total: roots.count, partial: reports, failures: failures)
                notify()
            }
            guard !Task.isCancelled else { return }
            workspaceState = .loaded(reports: reports, failures: failures)
            workspaceTask = nil
            notify()
        }
        workspaceTask = task
        notify()
        return task
    }

    func relatedPaths(for root: URL) -> Set<String> {
        let key = key(root)
        var keys: Set = [key, canonicalPath(root)]
        if let report = states[key]?.report {
            keys.formUnion(states.filter { $0.value.report?.id == report.id }.keys)
            keys.formUnion(report.checkouts.map(\.id))
        }
        keys.formUnion(aliases.filter { keys.contains($0.value) }.keys)
        return keys
    }

    func invalidate(repositoryRoot root: URL) {
        let invalidated = relatedPaths(for: root)
        aliases = aliases.filter { !invalidated.contains($0.value) }
        for path in invalidated {
            scans.removeValue(forKey: path)?.cancel()
            healthTasks.removeValue(forKey: path)?.cancel()
            healthStates[path] = nil
            states[path] = nil
        }
        resetWorkspace()
        notify()
    }

    func invalidateAll() {
        cancelActiveScans()
        states.removeAll()
        aliases.removeAll()
        healthStates.removeAll()
        resetWorkspace()
        notify()
    }

    func cancelActiveScans() {
        for (key, task) in scans {
            task.cancel()
            states[key] = nil
        }
        scans.removeAll()
        for (key, task) in healthTasks {
            task.cancel()
            healthStates[key] = nil
        }
        healthTasks.removeAll()
        if workspaceTask != nil { resetWorkspace() }
        notify()
    }

    private func resetWorkspace() {
        workspaceTask?.cancel()
        workspaceTask = nil
        workspaceState = .idle
    }
}
