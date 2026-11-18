import AppKit
import GitaCore

/// The agent sessions the main window shows. Reads `AgentMonitor` and fans changes out to every window view through
/// one notification.
@MainActor
final class WindowAgents {
    static let shared = WindowAgents()
    static let didChange = Notification.Name("dev.clevermechanisms.Gita.windowAgentsChanged")
    private(set) var sessions: [AgentSession] = []
    private var sessionKeys: [(repository: String?, checkout: String?)] = []
    private var started = false
    private let monitor: AgentMonitor
    private let center: NotificationCenter

    init(monitor: AgentMonitor = .shared, center: NotificationCenter = .default) {
        self.monitor = monitor
        self.center = center
    }

    func start() {
        guard !started else { return }
        started = true
        monitor.observe { [weak self] sessions in self?.publish(sessions) }
        monitor.start()
        publish(monitor.sessions)
    }
    /// Most urgent first, then the most recent state change first.
    static func ordered(_ sessions: [AgentSession]) -> [AgentSession] {
        sessions.sorted { $0.state != $1.state ? $0.state < $1.state : $0.stateSince > $1.stateSince }
    }
    func publish(_ live: [AgentSession]) {
        let next = Self.ordered(live)
        guard next != sessions else { return }
        sessions = next
        // Symlinks are resolved once per path per agent update, not on every sidebar, tab and history rebuild.
        Self.keys.removeAll(keepingCapacity: true)
        sessionKeys = next.map { (Self.key($0.repositoryRoot), Self.key($0.checkoutRoot ?? $0.workingDirectory)) }
        center.post(name: Self.didChange, object: self)
    }

    // MARK: Paths

    private static var keys: [String: String] = [:]
    private static let keyCacheLimit = 4_096
    /// The comparable form of a path (standardized, symlinks resolved). Resolving costs file-system calls per
    /// component, so results are memoized until the next agent update.
    static func key(_ url: URL?) -> String? {
        guard let url else { return nil }
        let raw = url.path
        if let cached = keys[raw] { return cached }
        let value = url.standardizedFileURL.resolvingSymlinksInPath().path
        if keys.count > keyCacheLimit { keys.removeAll(keepingCapacity: true) }
        keys[raw] = value
        return value
    }

    // MARK: Queries

    /// Sessions in this repository's main checkout or any of its worktrees (`worktreePaths` from the snapshot/status).
    func sessions(repository root: URL, worktreePaths: [String] = []) -> [AgentSession] {
        guard let rootKey = Self.key(root) else { return [] }
        let trees = Set(worktreePaths.compactMap { Self.key(URL(fileURLWithPath: $0)) })
        return zip(sessions, sessionKeys).filter { _, keys in
            if let repository = keys.repository, repository == rootKey { return true }
            guard let checkout = keys.checkout else { return false }
            return checkout == rootKey || trees.contains(checkout)
        }.map(\.0)
    }
    func sessions(checkout path: URL) -> [AgentSession] {
        guard let key = Self.key(path) else { return [] }
        return zip(sessions, sessionKeys).filter { $0.1.checkout == key }.map(\.0)
    }
    /// Agents across the Mac, a subagent counted with the agent it works for.
    var summary: AgentSummary { AgentSummary(sessions.filter { !Self.folds($0, in: sessions) }) }

    /// Brings the agent's terminal forward in its app; beeps when no app is known (never a Finder window instead).
    func reveal(_ session: AgentSession) {
        if !monitor.reveal(session) { NSSound.beep() }
    }
    /// The app that shows the agent's terminal, by name and icon ("Orca", "Terminal", "iTerm2"); nil when unknown.
    func hostApp(_ session: AgentSession) -> (name: String, icon: NSImage)? {
        switch monitor.host(of: session) {
        case nil: return nil
        case .orca:
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: AgentMonitor.orcaBundleID) else {
                return nil
            }
            return (Deck.applicationName(at: url), NSWorkspace.shared.icon(forFile: url.path))
        case .app(let pid):
            guard let app = NSRunningApplication(processIdentifier: pid), let name = app.localizedName else {
                return nil
            }
            return (name, app.icon ?? NSWorkspace.shared.icon(for: .application))
        }
    }
    /// "Show in Orca" for the agent's terminal, or the generic title when its app is unknown.
    func revealTitle(_ session: AgentSession) -> String {
        hostApp(session).map { String(localized: "Show in \($0.name)") } ?? String(localized: "Bring Terminal Forward")
    }
    func markSeen(repository root: URL) { monitor.markSeen(repository: root) }

    // MARK: Subagents

    // Several agents in one checkout, and subagents. A subagent is folded into the session that started it when that
    // session is present and works in the same checkout (unless the subagent itself waits for input): lists show the
    // parent once with a subagent count instead of one identical row per subagent.
    static func folds(_ session: AgentSession, in sessions: [AgentSession]) -> Bool {
        guard session.isSubagent, session.state != .needsInput, let parentID = session.parentID,
            let parent = sessions.first(where: { $0.id == parentID })
        else { return false }
        return key(parent.checkoutRoot ?? parent.workingDirectory)
            == key(session.checkoutRoot ?? session.workingDirectory)
    }
    static func subagents(of session: AgentSession, in sessions: [AgentSession]) -> [AgentSession] {
        sessions.filter { $0.parentID == session.id }
    }
    /// One checkout's sessions as its lead (the most urgent top-level agent), how many other top-level agents work
    /// there, and how many subagents. `sessions` is ordered most urgent first.
    struct Crowd: Equatable {
        var lead: AgentSession
        var others: Int
        var subagents: Int
        var state: AgentState
    }
    static func crowd(_ sessions: [AgentSession]) -> Crowd? {
        guard let lead = sessions.first(where: { !$0.isSubagent }) ?? sessions.first else { return nil }
        let topLevel = sessions.filter { !$0.isSubagent && $0.id != lead.id }.count
        let subagents = sessions.filter { $0.isSubagent && $0.id != lead.id }.count
        return Crowd(
            lead: lead, others: topLevel, subagents: subagents, state: AgentSummary(sessions).state ?? lead.state)
    }
}
