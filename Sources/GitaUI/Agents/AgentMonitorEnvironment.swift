import AppKit
import GitaCore

/// Everything `AgentMonitor` reads from the system: the process scan, checkout resolution, the hook socket, Orca,
/// settings, the user's home and the clocks. Tests replace these so no real process, socket or home is touched.
@MainActor
struct AgentMonitorEnvironment {
    /// One agent session Orca reports: its checkout, its task title, and its tool and state when Orca knows them.
    struct OrcaSession: Sendable {
        let path: String
        var title: String?
        var tool: AgentTool?
        var state: AgentState?
    }
    var scan: @Sendable () async -> [AgentProcessSample]
    var resolve: @Sendable (_ directory: String, _ allowedRoots: [String]) async -> AgentCheckout?
    /// Opens the hook socket; nil leaves hooks off (sampling still works).
    var listen: (@escaping @Sendable (AgentHookEvent) -> Void) -> AgentEventListener?
    /// Repositories the user opened, the only places privacy-protected folders are resolved in.
    var allowedRoots: () -> [String] = { WorkspaceMonitor.shared.statuses.map(\.root.path) }
    var orcaSessions: @Sendable (URL) async -> [OrcaSession] = Self.readOrcaSessions
    /// Orca's CLI is asked only while the app runs (it never starts the Orca runtime).
    var orcaRunning: () -> Bool = {
        !NSRunningApplication.runningApplications(withBundleIdentifier: BrandMarks.orca).isEmpty
    }
    var defaults: UserDefaults = Preference.store
    var home: URL = FileManager.default.homeDirectoryForCurrentUser
    var helpers: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
    /// Hooks point at this copy's helper, so only the installed app (see `LoginItem.isInstalledCopy`) installs them.
    var isInstalledCopy: () -> Bool = { LoginItem.isInstalledCopy }
    var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var now: () -> Date = Date.init
    var revealer = AgentHostRevealer()

    init() {
        let scanner = AgentProcessScanner()
        let resolver = AgentCheckoutResolver()
        scan = { await scanner.scan() }
        resolve = { await resolver.resolve($0, allowedRoots: $1) }
        listen = Self.openSocket
    }

    private static func openSocket(_ handler: @escaping @Sendable (AgentHookEvent) -> Void) -> AgentEventListener? {
        #if DEBUG
            let development = true
        #else
            let development = false
        #endif
        return try? AgentEventListener(path: AgentEventSocket.path(development: development), handler: handler)
    }

    /// Each Orca session's checkout, task title, tool and state in one repository.
    private static let readOrcaSessions: @Sendable (URL) async -> [OrcaSession] = { root in
        let report = await ProviderService().orca(root: root)
        return report.items.compactMap { item in
            guard let agent = item.agent, agent.role == .session, let path = item.worktreePath else { return nil }
            return OrcaSession(
                path: path, title: agent.taskTitle ?? agent.sessionName, tool: item.reportedAgentTool,
                state: item.reportedAgentState)
        }
    }
}
