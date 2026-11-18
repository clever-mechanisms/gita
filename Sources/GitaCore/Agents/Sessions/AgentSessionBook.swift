import Foundation

/// The session state machine behind `AgentMonitor`: merges process samples (inferred states) and hook events (exact
/// states) into `AgentSession`s. A value type with injected clocks so every rule is unit-tested.
///
/// Rules:
/// * A service process (no terminal, daemon, desktop-app helper) is a session only inside a Git checkout.
/// * Without hooks, CPU decides: sustained work → working; a finished turn (≥ 10 s of work) → done + unseen; a short
///   burst → idle.
/// * Orca reports the state of a session in its terminals (`applyReported`); while those reports keep coming, they own
///   the state of a session without hooks, and a reported working → idle is a finished turn (done + unseen).
/// * Once a session has reported through a hook, hooks own its state. CPU only resolves what hooks cannot report:
///   work resuming after an approved permission prompt (needs input → working) and an interrupted turn, which sends no
///   `Stop` (working → idle after 120 s without CPU activity).
/// * `SessionEnd` hides the process until it exits; `SessionEnd` with reason `clear` (`/clear`) only resets to idle.
/// * Seen finished work becomes idle (`markSeen`).
public struct AgentSessionBook: Sendable {
    public static let resumeGrace: TimeInterval = 3
    public static let interruptedAfter: TimeInterval = 120
    public static let hookOnlyLifetime: TimeInterval = 30 * 60
    /// How long a reported state stands without a newer report before CPU inference takes over again.
    public static let reportLifetime: TimeInterval = 90

    /// Who decides a session's state. Hooks, once seen, own it for the session's life; a report owns it until
    /// `reportLifetime` passes without a newer one, and CPU inference (`process`) decides otherwise.
    enum Owner: Sendable, Equatable {
        case process
        /// The latest report arrived at `time` (the trackers' clock).
        case reported(time: TimeInterval)
        case hooked(Hook)

        var hook: Hook? {
            if case .hooked(let hook) = self { hook } else { nil }
        }
    }

    /// The latest hook: `time` on the trackers' clock, `date` on the wall clock (hook-only sessions expire by it);
    /// `sessionID` matches later hooks that name no agent process.
    struct Hook: Sendable, Equatable {
        var time: TimeInterval
        var date: Date
        var sessionID: String?
    }

    struct Entry: Sendable {
        var id: String
        var tool: AgentTool
        var pid: Int32?
        var parentAgentPID: Int32?
        var workingDirectory: String
        var startedAt: Date?
        var checkout: AgentCheckout?
        var tracker = AgentActivityTracker()
        var state: AgentState = .idle
        var stateSince: Date
        var unseen = false
        var owner = Owner.process
    }

    public enum HookOutcome: Equatable, Sendable {
        case applied
        case removed
        /// No session matched yet; the caller rescans (a brand-new process) and offers the event again.
        case unmatched
        /// A hook-only session was created for a folder whose checkout the caller should resolve.
        case created(id: String, directory: String)
        case ignored
    }

    private(set) var entries: [String: Entry] = [:]
    private var endedPIDs = Set<Int32>()
    private let configuration: AgentActivityTracker.Configuration

    public init(configuration: AgentActivityTracker.Configuration = .init()) { self.configuration = configuration }

    // MARK: Samples

    /// `time` is a monotonic clock in seconds (the trackers' clock); `now` stamps `stateSince`.
    public mutating func apply(
        _ samples: [AgentProcessSample], checkouts: [String: AgentCheckout], enabled: Set<AgentTool>,
        time: TimeInterval, now: Date
    ) {
        endedPIDs.formIntersection(samples.map(\.pid))
        var live = Set<String>()
        for sample in samples where enabled.contains(sample.tool) && !endedPIDs.contains(sample.pid) {
            let checkout = checkouts[sample.workingDirectory]
            if sample.isService && checkout == nil { continue }
            let id = "\(sample.tool.rawValue)-\(sample.pid)"
            live.insert(id)
            var entry =
                entries[id]
                ?? Entry(
                    id: id, tool: sample.tool, pid: sample.pid, workingDirectory: sample.workingDirectory,
                    startedAt: sample.startedAt, tracker: AgentActivityTracker(configuration: configuration),
                    stateSince: sample.startedAt)
            entry.parentAgentPID = sample.parentAgentPID
            entry.workingDirectory = sample.workingDirectory
            entry.checkout = checkout
            let transition = entry.tracker.add(time: time, cpu: sample.cpuSeconds)
            infer(&entry, transition: transition, time: time, now: now)
            entries[id] = entry
        }
        for (id, entry) in entries {
            if entry.pid != nil {
                if !live.contains(id) { entries[id] = nil }
                continue
            }
            // Hook-only: dropped once a process session of the tool covers the folder, or after 30 min of silence.
            let covered = entries.values.contains {
                $0.pid != nil && $0.tool == entry.tool && $0.workingDirectory == entry.workingDirectory
            }
            if covered || !enabled.contains(entry.tool)
                || now.timeIntervalSince(entry.owner.hook?.date ?? now) > Self.hookOnlyLifetime
            {
                entries[id] = nil
            }
        }
    }

    private func infer(
        _ entry: inout Entry, transition: AgentActivityTracker.Transition?, time: TimeInterval, now: Date
    ) {
        switch entry.owner {
        case .hooked(let hook):
            resolveHooked(&entry, lastHook: hook.time, time: time, now: now)
            return
        case .reported(let lastReport) where time - lastReport < Self.reportLifetime:
            return
        case .reported:
            // The reports stopped: CPU decides again, and the session no longer claims Orca as its evidence.
            entry.owner = .process
        case .process:
            break
        }
        switch transition {
        case .started: Self.set(&entry, .working, now: now)
        case .finished: Self.set(&entry, .done, now: now, unseen: true)
        case .settled: if entry.state == .working { Self.set(&entry, .idle, now: now) }
        case nil: break
        }
    }

    /// What hooks cannot report: work resuming after an approved permission prompt, and an interrupted turn.
    private func resolveHooked(_ entry: inout Entry, lastHook: TimeInterval, time: TimeInterval, now: Date) {
        let tracker = entry.tracker
        if entry.state == .needsInput, tracker.isWorking, let since = tracker.workingSince,
            since > lastHook + Self.resumeGrace
        {
            Self.set(&entry, .working, now: now)
        } else if entry.state == .working,
            time - max(lastHook, tracker.lastBusy ?? lastHook) > Self.interruptedAfter
        {
            Self.set(&entry, .idle, now: now)
        }
    }

    private static func set(_ entry: inout Entry, _ state: AgentState, now: Date, unseen: Bool = false) {
        entry.unseen = unseen
        guard entry.state != state else { return }
        entry.state = state
        entry.stateSince = now
    }

    // MARK: Hooks

    public mutating func handle(
        _ event: AgentHookEvent, enabled: Set<AgentTool>, allowHookOnly: Bool,
        time: TimeInterval, now: Date
    ) -> HookOutcome {
        guard enabled.contains(event.tool) else { return .ignored }
        let effect = event.effect
        guard effect != .ignored else { return .ignored }
        guard let id = match(event), var entry = entries[id] else {
            guard allowHookOnly || event.pids.isEmpty else { return .unmatched }
            guard effect != .ended, let session = event.sessionID, let cwd = event.cwd else { return .ignored }
            let id = "\(event.tool.rawValue)-\(session)"
            var entry =
                entries[id]
                ?? Entry(
                    id: id, tool: event.tool, pid: nil, workingDirectory: cwd,
                    tracker: AgentActivityTracker(configuration: configuration), stateSince: now)
            Self.apply(effect, to: &entry, event: event, time: time, now: now)
            let isNew = entries[id] == nil
            entries[id] = entry
            return isNew ? .created(id: id, directory: cwd) : .applied
        }
        if effect == .ended {
            if let pid = entry.pid { endedPIDs.insert(pid) }
            entries[id] = nil
            return .removed
        }
        Self.apply(effect, to: &entry, event: event, time: time, now: now)
        entries[id] = entry
        return .applied
    }

    /// The nearest ancestor of the hook that is a known agent process; then the hook's session id; then the folder,
    /// when exactly one session of that tool works there.
    func match(_ event: AgentHookEvent) -> String? {
        for pid in event.pids {
            if let entry = entries.values.first(where: { $0.pid == pid && $0.tool == event.tool }) { return entry.id }
        }
        if let session = event.sessionID,
            let entry = entries.values.first(where: { $0.tool == event.tool && $0.owner.hook?.sessionID == session })
        {
            return entry.id
        }
        guard let cwd = event.cwd else { return nil }
        let candidates = entries.values.filter {
            $0.tool == event.tool && ($0.workingDirectory == cwd || $0.checkout?.checkoutRoot.path == cwd)
        }
        return candidates.count == 1 ? candidates[0].id : nil
    }

    private static func apply(
        _ effect: AgentHookEvent.Effect, to entry: inout Entry, event: AgentHookEvent, time: TimeInterval, now: Date
    ) {
        entry.owner = .hooked(Hook(time: time, date: now, sessionID: event.sessionID ?? entry.owner.hook?.sessionID))
        switch effect {
        case .working: set(&entry, .working, now: now)
        case .needsInput: set(&entry, .needsInput, now: now)
        case .done: set(&entry, .done, now: now, unseen: true)
        case .cleared: set(&entry, .idle, now: now)
        case .ended, .ignored: break
        }
    }

    // MARK: Reported states (Orca)

    /// States another app reports (Orca, for the agents in its terminals). A report applies where exactly one
    /// session of its tool runs in its checkout, exactly one report names that checkout and tool, and the session
    /// has no hooks (hooks are exact and instant). Returns whether any state changed.
    @discardableResult
    public mutating func applyReported(_ reports: [AgentStateReport], time: TimeInterval, now: Date) -> Bool {
        var byKey: [String: [AgentStateReport]] = [:]
        for report in reports { byKey["\(report.tool.rawValue)|\(report.checkout)", default: []].append(report) }
        var changed = false
        for case (_, let group) in byKey where group.count == 1 {
            let report = group[0]
            let matches = entries.values.filter {
                $0.tool == report.tool && $0.checkout?.checkoutRoot.path == report.checkout
            }
            guard matches.count == 1, var entry = entries[matches[0].id], entry.owner.hook == nil else { continue }
            let before = (entry.state, entry.unseen)
            entry.owner = .reported(time: time)
            switch report.state {
            case .working, .needsInput: Self.set(&entry, report.state, now: now)
            case .done: if entry.state != .done { Self.set(&entry, .done, now: now, unseen: true) }
            case .idle:
                if entry.state == .working {
                    Self.set(&entry, .done, now: now, unseen: true)
                } else if entry.state != .done {
                    Self.set(&entry, .idle, now: now)
                }
            }
            changed = changed || before != (entry.state, entry.unseen)
            entries[entry.id] = entry
        }
        return changed
    }

    // MARK: Updates and output

    public mutating func setCheckout(_ checkout: AgentCheckout, for id: String) { entries[id]?.checkout = checkout }

    /// Finished sessions among `ids` become idle.
    public mutating func markSeen(_ ids: Set<String>, now: Date) {
        for id in ids {
            guard var entry = entries[id], entry.state == .done else { continue }
            Self.set(&entry, .idle, now: now)
            entries[id] = entry
        }
    }

    public var repositoryRoots: Set<URL> { Set(entries.values.compactMap { $0.checkout?.repositoryRoot }) }

    /// Sessions most urgent first, then most recent `stateSince`. `titles` (checkout path → task title, e.g. from Orca)
    /// apply only where exactly one session works in that checkout.
    public func sessions(titles: [String: String] = [:]) -> [AgentSession] {
        var perCheckout: [String: Int] = [:]
        for entry in entries.values {
            if let path = entry.checkout?.checkoutRoot.path { perCheckout[path, default: 0] += 1 }
        }
        return entries.values.map { entry in
            let title = entry.checkout.flatMap {
                perCheckout[$0.checkoutRoot.path] == 1 ? titles[$0.checkoutRoot.path] : nil
            }
            return AgentSession(
                id: entry.id, tool: entry.tool, pid: entry.pid,
                workingDirectory: URL(fileURLWithPath: entry.workingDirectory, isDirectory: true),
                checkoutRoot: entry.checkout?.checkoutRoot, repositoryRoot: entry.checkout?.repositoryRoot,
                branch: entry.checkout?.branch,
                state: entry.state, stateSince: entry.stateSince, startedAt: entry.startedAt,
                evidence: Self.evidence(entry.owner, titled: title != nil),
                title: title, isSubagent: entry.parentAgentPID != nil,
                parentID: entry.parentAgentPID.map { "\(entry.tool.rawValue)-\($0)" }, unseen: entry.unseen)
        }.sorted(by: Self.order)
    }

    /// A session Orca titles shows Orca as its evidence even while CPU decides its state.
    private static func evidence(_ owner: Owner, titled: Bool) -> AgentEvidence {
        switch owner {
        case .hooked: .hook
        case .reported: .orca
        case .process: titled ? .orca : .process
        }
    }

    public static func order(_ lhs: AgentSession, _ rhs: AgentSession) -> Bool {
        if lhs.state != rhs.state { return lhs.state < rhs.state }
        if lhs.stateSince != rhs.stateSince { return lhs.stateSince > rhs.stateSince }
        return lhs.id < rhs.id
    }
}
