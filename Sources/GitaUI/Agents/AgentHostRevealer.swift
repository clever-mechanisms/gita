import AppKit
import GitaCore

/// The app whose window shows an agent's terminal.
enum AgentHost: Equatable {
    /// Orca. Its terminals run under "Orca Terminal Host", a background process that outlives Orca.app and hangs off
    /// launchd, so the app is never among the agent's ancestors; the tab is found through the Orca CLI instead.
    case orca
    /// A regular app among the agent's ancestors (Terminal, iTerm, Ghostty, Warp, VS Code, Cursor…).
    case app(pid_t)
}

/// Finds the app showing an agent's terminal and brings it to the front. The process table, running apps and
/// activation come in as closures, so tests reveal nothing.
@MainActor
struct AgentHostRevealer {
    /// A running app as the revealer needs it.
    struct App: Equatable {
        var bundleIdentifier: String?
        /// A regular (Dock) app other than Gita itself.
        var isCandidate: Bool
    }

    /// Switches Orca to the agent's terminal through its CLI.
    var switchOrcaTerminal: @Sendable (_ checkout: URL, _ title: String?) async -> Void = { checkout, title in
        _ = await ProviderService().orcaSwitchTerminal(checkout: checkout, title: title)
    }
    /// The process and its ancestors, nearest first.
    var lineage: @MainActor (pid_t) -> [pid_t] = { [$0] + AgentProcessTable.ancestors(of: $0) }
    var executablePath: @MainActor (pid_t) -> String? = { AgentProcessTable.executablePath($0) }
    /// The app running as this process, if any.
    var app: @MainActor (pid_t) -> App? = Self.runningApp
    /// Brings the app with this process to the front; false when it is gone or refuses.
    var activate: @MainActor (pid_t) -> Bool = Self.activateApp
    /// Brings Orca to the front, launching it if needed; false when it is not installed.
    var activateOrca: @MainActor () -> Bool = Self.activateOrcaApp

    func host(of session: AgentSession) -> AgentHost? {
        guard let pid = session.pid else { return nil }
        for ancestor in lineage(pid) {
            if let path = executablePath(ancestor), Self.isOrcaExecutable(path) { return .orca }
            guard let app = app(ancestor), app.isCandidate else { continue }
            return app.bundleIdentifier == BrandMarks.orca ? .orca : .app(ancestor)
        }
        return nil
    }

    static func isOrcaExecutable(_ path: String) -> Bool {
        path.hasSuffix("/orca-terminal-host") || path.contains("/Orca.app/Contents/")
    }

    /// Brings the app that shows the agent's terminal to the front (see `host(of:)`); in Orca, also switches to
    /// the agent's terminal. False when no such app is known.
    func reveal(_ session: AgentSession) -> Bool {
        switch host(of: session) {
        case nil: return false
        case .orca: return revealInOrca(session)
        case .app(let pid): return activate(pid)
        }
    }

    private func revealInOrca(_ session: AgentSession) -> Bool {
        guard activateOrca() else { return false }
        let checkout = session.checkoutRoot ?? session.workingDirectory
        let title = session.title
        let switchOrcaTerminal = switchOrcaTerminal
        Task { await switchOrcaTerminal(checkout, title) }
        return true
    }

    private static func runningApp(_ pid: pid_t) -> App? {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        return App(
            bundleIdentifier: app.bundleIdentifier,
            isCandidate: app.activationPolicy == .regular && app != NSRunningApplication.current)
    }

    private static func activateApp(_ pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        NSApp.yieldActivation(to: app)
        return app.activate()
    }

    private static func activateOrcaApp() -> Bool {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: BrandMarks.orca).first {
            NSApp.yieldActivation(to: app)
            app.activate()
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: BrandMarks.orca) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else {
            return false
        }
        return true
    }
}
