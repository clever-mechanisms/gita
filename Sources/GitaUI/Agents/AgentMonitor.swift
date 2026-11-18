import AppKit
import GitaCore

/// One process-wide view of every coding agent on this Mac (Claude Code, Codex, opencode…), with or without Orca.
///
/// * Processes come from a libproc scan (no subprocesses) every 2 s while agent UI is visible (`setVisible(true)`),
///   every 30 s (10 s tolerance) otherwise; folders map to checkouts with one cached `git rev-parse` per folder.
/// * Working/idle is inferred from CPU (process + recent children) with hysteresis; a finished turn of at least 10 s
///   becomes `done` + `unseen` until `markSeen`.
/// * With Orca on and running, Orca reports the state of the agents in its terminals (any tool it knows), read every
///   3 s while agent UI is visible, every 30 s otherwise; no hooks of Gitā's are needed for those.
/// * Hooks (`installHooks`) report exact states instantly over a socket; once a session reports through hooks, CPU only
///   resolves the two cases hooks miss (an approved permission prompt, an interrupted turn).
/// * No transcript or prompt content is ever read.
@MainActor
final class AgentMonitor {
    static let shared = AgentMonitor()
    static var orcaBundleID: String { BrandMarks.orca }

    /// All live sessions, most urgent first (needs input, working, done, idle), then most recent `stateSince`.
    private(set) var sessions: [AgentSession] = []

    let environment: AgentMonitorEnvironment
    private var book = AgentSessionBook()
    private var observers: [UUID: @MainActor ([AgentSession]) -> Void] = [:]
    private var listener: AgentEventListener?
    private var timer: Timer?
    private var scanTask: Task<Void, Never>?
    private var rescanRequested = false
    private var unmatchedEvents: [AgentHookEvent] = []
    private(set) var isRunning = false
    private var visible = false
    private var orca = OrcaRead.idle(lastRead: nil)
    private var orcaTitles: [String: String] = [:]
    private var preferenceObserver: NSObjectProtocol?
    private var normalizedRoots: [String: String] = [:]
    private static let normalizedLimit = 512

    init(environment: AgentMonitorEnvironment = AgentMonitorEnvironment()) { self.environment = environment }
    isolated deinit {
        timer?.invalidate()
        scanTask?.cancel()
        orca.cancel()
        listener?.cancel()
        if let preferenceObserver { NotificationCenter.default.removeObserver(preferenceObserver) }
    }

    /// Start sampling (idempotent). Cheap at rest: the scan runs every 2 s only while a window or the panel is visible,
    /// otherwise every 30 s with tolerance, and hook events arrive instantly. `observe` starts it too.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        listener = environment.listen { [weak self] event in
            Task { @MainActor in self?.handle(event, retry: true) }
        }
        preferenceObserver = NotificationCenter.default.addObserver(
            forName: .gitaPreferenceChanged, object: nil, queue: .main
        ) { [weak self] notification in
            let key = notification.userInfo?["key"] as? String ?? ""
            MainActor.assumeIsolated { self?.preferenceChanged(key) }
        }
        schedule()
        scanNow()
        // A second sample shortly after launch lets the CPU inference decide within ~1.5 s instead of one full period.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated { self?.scanNow() }
        }
    }

    private func preferenceChanged(_ key: String) {
        let orca = Preference.useOrca.rawValue
        guard key.hasPrefix("detect") || key == orca || key == Preference.useAgents.rawValue else { return }
        if key == orca {
            // A read in flight was asked under the old setting: its titles and states must not land after it.
            self.orca.cancel()
            self.orca = .idle(lastRead: nil)
            orcaTitles = [:]
            refreshOrcaIfDue()
        }
        scanNow()
    }

    /// The app tells the monitor whether any UI that shows agents is visible, so sampling can slow down.
    func setVisible(_ visible: Bool) {
        guard visible != self.visible else { return }
        self.visible = visible
        guard isRunning else { return }
        schedule()
        if visible {
            scanNow()
            refreshOrcaIfDue()
        }
    }

    /// Called on every change of `sessions` (not immediately; read `sessions` for the current list).
    @discardableResult func observe(_ handler: @escaping @MainActor ([AgentSession]) -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        start()
        return id
    }
    func removeObserver(_ id: UUID) { observers[id] = nil }

    /// Sessions whose `repositoryRoot` (or `checkoutRoot`) is `root` or one of its worktrees.
    func sessions(inRepository root: URL) -> [AgentSession] {
        let path = normalized(root)
        return sessions.filter { $0.repositoryRoot?.path == path || $0.checkoutRoot?.path == path }
    }
    func summary(forRepository root: URL) -> AgentSummary { AgentSummary(sessions(inRepository: root)) }
    var summary: AgentSummary { AgentSummary(sessions) }

    /// Clears `unseen` on finished sessions in this repository (called when its tab or row is shown): seen work is
    /// idle.
    func markSeen(repository root: URL) {
        let ids = Set(sessions(inRepository: root).filter { $0.state == .done }.map(\.id))
        guard !ids.isEmpty else { return }
        book.markSeen(ids, now: environment.now())
        publish()
    }

    // MARK: Terminal hosts

    func host(of session: AgentSession) -> AgentHost? { environment.revealer.host(of: session) }

    /// Brings the app that shows the agent's terminal to the front. False when no such app is known.
    @discardableResult func reveal(_ session: AgentSession) -> Bool { environment.revealer.reveal(session) }

    // MARK: Sampling

    /// The tools detected: none while the coding-agents integration is off.
    private var enabledTools: Set<AgentTool> {
        guard Integration.agents.isEnabled(environment.defaults) else { return [] }
        return Set(AgentTool.allCases.filter { $0.detectionPreference.bool(environment.defaults) })
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard isRunning else { return }
        let timer = Timer(timeInterval: visible ? 2 : 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scanNow()
                self?.refreshOrcaIfDue()
            }
        }
        timer.tolerance = visible ? 0.5 : 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func scanNow() {
        guard isRunning else { return }
        if scanTask != nil {
            rescanRequested = true
            return
        }
        let environment = environment
        let enabled = enabledTools
        // Nothing to detect (every tool or the whole integration off): no process scan, and the sessions go.
        guard !enabled.isEmpty else {
            apply([], checkouts: [:], enabled: enabled)
            return
        }
        // Privacy-protected folders are only resolved inside repositories the user opened in Gita.
        let allowed = environment.allowedRoots()
        scanTask = Task { [weak self] in
            let samples = await environment.scan().filter { enabled.contains($0.tool) }
            var checkouts: [String: AgentCheckout] = [:]
            await withTaskGroup(of: (String, AgentCheckout?).self) { group in
                for directory in Set(samples.map(\.workingDirectory)) {
                    group.addTask { (directory, await environment.resolve(directory, allowed)) }
                }
                for await (directory, checkout) in group { if let checkout { checkouts[directory] = checkout } }
            }
            guard let self, !Task.isCancelled else { return }
            self.scanTask = nil
            self.apply(samples, checkouts: checkouts, enabled: enabled)
            if self.rescanRequested {
                self.rescanRequested = false
                self.scanNow()
            }
        }
    }

    private func apply(_ samples: [AgentProcessSample], checkouts: [String: AgentCheckout], enabled: Set<AgentTool>) {
        book.apply(samples, checkouts: checkouts, enabled: enabled, time: environment.uptime(), now: environment.now())
        let pending = unmatchedEvents
        unmatchedEvents = []
        for event in pending { handle(event, retry: false) }
        publish()
    }

    // MARK: Hooks

    /// Hook events update the session at once; an event from a process the last scan has not seen yet triggers a scan
    /// and is offered again afterwards.
    func handle(_ event: AgentHookEvent, retry: Bool) {
        guard isRunning else { return }
        switch book.handle(
            event, enabled: enabledTools, allowHookOnly: !retry, time: environment.uptime(), now: environment.now())
        {
        case .unmatched:
            unmatchedEvents.append(event)
            scanNow()
        case .created(let id, let directory):
            publish()
            let environment = environment
            let allowed = environment.allowedRoots()
            Task { [weak self] in
                guard let checkout = await environment.resolve(directory, allowed), let self else { return }
                self.book.setCheckout(checkout, for: id)
                self.publish()
            }
        case .applied, .removed:
            publish()
        case .ignored:
            break
        }
    }

    // MARK: Orca (optional)

    /// Orca's sessions, when `Preference.useOrca` is on and Orca runs: their task titles by checkout path, and their
    /// states for the sessions without hooks (`AgentSessionBook.applyReported`); never required.
    private func refreshOrcaIfDue() {
        guard isRunning, Preference.useOrca.bool(environment.defaults), case .idle(let lastRead) = orca,
            environment.orcaRunning()
        else { return }
        let now = environment.now()
        if let lastRead, now.timeIntervalSince(lastRead) < (visible ? 3 : 30) - 0.5 { return }
        let roots = Array(book.repositoryRoots.prefix(8))
        guard !roots.isEmpty else { return }
        let id = UUID()
        let environment = environment
        let task = Task { [weak self] in
            var sessions: [AgentMonitorEnvironment.OrcaSession] = []
            await withTaskGroup(of: [AgentMonitorEnvironment.OrcaSession].self) { group in
                for root in roots { group.addTask { await environment.orcaSessions(root) } }
                for await found in group { sessions += found }
            }
            guard let self, !Task.isCancelled, self.orca.isReading(id) else { return }
            self.orca = .idle(lastRead: now)
            self.applyOrca(sessions)
        }
        orca = .reading(id: id, task: task)
    }

    private func applyOrca(_ sessions: [AgentMonitorEnvironment.OrcaSession]) {
        // A checkout with several Orca sessions has no single title.
        var titles: [String: [String]] = [:]
        for session in sessions { if let title = session.title { titles[session.path, default: []].append(title) } }
        orcaTitles = titles.compactMapValues { $0.count == 1 ? $0[0] : nil }
        let reports = sessions.compactMap { session in
            session.tool.flatMap { tool in
                session.state.map { AgentStateReport(tool: tool, checkout: session.path, state: $0) }
            }
        }
        book.applyReported(reports, time: environment.uptime(), now: environment.now())
        publish()
    }

    /// Orca's report, read at most once per period: idle since the last read (none yet, or Orca was just turned
    /// on or off), or one read in flight. Only the read in flight may land, so a read cancelled by the setting is
    /// dropped even if its results arrive.
    enum OrcaRead {
        case idle(lastRead: Date?)
        case reading(id: UUID, task: Task<Void, Never>)

        func isReading(_ id: UUID) -> Bool {
            if case .reading(let current, _) = self { current == id } else { false }
        }

        func cancel() {
            if case .reading(_, let task) = self { task.cancel() }
        }
    }

    // MARK: Publishing

    private func publish() {
        let list = book.sessions(titles: Preference.useOrca.bool(environment.defaults) ? orcaTitles : [:])
        guard list != sessions else { return }
        sessions = list
        for handler in Array(observers.values) { handler(list) }
    }

    /// Git reports real paths; roots from the UI may contain symlinks (`/var` → `/private/var`).
    private func normalized(_ root: URL) -> String {
        let path = root.standardizedFileURL.path
        if let cached = normalizedRoots[path] { return cached }
        let resolved = root.standardizedFileURL.resolvingSymlinksInPath().path
        if normalizedRoots.count > Self.normalizedLimit { normalizedRoots.removeAll() }
        normalizedRoots[path] = resolved
        return resolved
    }
}
