import AppKit
import GitaCore

/// What a tool row shows for its check state.
struct SetupToolRow: Equatable {
    /// The row's button: what it is called and does.
    enum Action: Equatable {
        case installCommandLineTools, brewInstall, download, setIdentity, signIn, retry
    }
    enum Tone: Equatable { case none, running, idle, attention, success, failure }

    var status: String
    var tone: Tone
    var statusTooltip: String?
    var action: Action?
    var actionTitle: String = ""
    var actionSymbol: String = ""
    var actionTooltip: String?

    /// `installing` wins over the last check; `hasHomebrew` picks between installing and the download page.
    static func make(_ tool: SetupTool, state: SetupToolState?, installing: Bool, hasHomebrew: Bool) -> Self {
        if installing { return Self(status: String(localized: "Installing…"), tone: .running) }
        switch state {
        case nil: return Self(status: String(localized: "Checking…"), tone: .none)
        case .missing?: return missing(tool, hasHomebrew: hasHomebrew)
        case .needsIdentity(let version)?:
            return Self(
                status: String(localized: "Name and email not set"), tone: .attention, statusTooltip: version,
                action: .setIdentity, actionTitle: String(localized: "Set Identity…"),
                actionSymbol: "person.crop.circle")
        case .signedOut(let version)?:
            let command = ([tool.executable] + tool.signInArguments).joined(separator: " ")
            return Self(
                status: String(localized: "Sign in required"), tone: .attention, statusTooltip: version,
                action: .signIn, actionTitle: String(localized: "Sign In…"), actionSymbol: "person.crop.circle",
                actionTooltip: String(localized: "Runs \(command) in Terminal."))
        case .ready(let detail)?: return Self(status: detail, tone: .success)
        case .failed(let message)?:
            return Self(
                status: String(localized: "Unavailable"), tone: .failure, statusTooltip: message, action: .retry,
                actionTitle: String(localized: "Retry"), actionSymbol: "arrow.clockwise")
        }
    }
    private static func missing(_ tool: SetupTool, hasHomebrew: Bool) -> Self {
        let status = String(localized: "Not installed")
        if tool == .git {
            return Self(
                status: status, tone: .idle, action: .installCommandLineTools,
                actionTitle: String(localized: "Install…"),
                actionSymbol: "arrow.down.circle",
                actionTooltip: String(localized: "Installs Apple's Command Line Tools, which include Git."))
        }
        if hasHomebrew {
            return Self(
                status: status, tone: .idle, action: .brewInstall, actionTitle: String(localized: "Install"),
                actionSymbol: "arrow.down.circle", actionTooltip: "brew install " + tool.formula)
        }
        return Self(
            status: status, tone: .idle, action: .download, actionTitle: String(localized: "Download"),
            actionSymbol: "arrow.up.right.square", actionTooltip: tool.downloadURL.absoluteString)
    }
}

/// An agent row: whether Gita's hooks and skill are in place, and what Install would do.
struct AgentConnectionState: Equatable {
    enum Tone: Equatable { case idle, attention, success }

    var status: String
    var tone: Tone
    var actionTitle: String
    var showsAction: Bool
    /// Why the hooks or the skill cannot be installed, one reason per line; nil when there is none.
    var unavailableReasons: String?

    /// `toolMissing`: the agent itself is not installed (its configuration folder does not exist). `throughOrca`: Orca
    /// reports the agents' states, so nothing of Gitā's is offered unless some of it is already there.
    static func make(
        hooks: AgentMonitor.HookStatus, skill: AgentHookInstallState, toolMissing: Bool, throughOrca: Bool = false
    ) -> Self {
        let hooksDone = hooks == .installed
        let skillDone = skill == .installed
        let needsUpdate = hooks == .needsUpdate || skill == .needsUpdate
        if throughOrca && !toolMissing && !hooksDone && !skillDone && !needsUpdate {
            return Self(
                status: throughOrcaStatus, tone: .success, actionTitle: String(localized: "Install"),
                showsAction: false, unavailableReasons: nil)
        }
        let open = hooks == .notInstalled || skill == .notInstalled || needsUpdate
        let (status, tone) = summary(
            hooksDone: hooksDone, skillDone: skillDone, needsUpdate: needsUpdate, toolMissing: toolMissing)
        var reasons: [String] = []
        if case .unavailable(let reason) = hooks, !toolMissing { reasons.append(reason) }
        if case .unavailable(let reason) = skill, !toolMissing { reasons.append(reason) }
        return Self(
            status: status, tone: tone,
            actionTitle: needsUpdate ? String(localized: "Update") : String(localized: "Install"), showsAction: open,
            unavailableReasons: reasons.isEmpty ? nil : reasons.joined(separator: "\n"))
    }
    private static func summary(
        hooksDone: Bool, skillDone: Bool, needsUpdate: Bool, toolMissing: Bool
    ) -> (String, Tone) {
        if toolMissing { return (String(localized: "Not installed"), .idle) }
        if hooksDone && skillDone { return (String(localized: "Hooks and skill"), .success) }
        if needsUpdate { return (String(localized: "Update available"), .attention) }
        if hooksDone { return (String(localized: "Hooks"), .success) }
        if skillDone { return (String(localized: "Skill"), .success) }
        return (String(localized: "Not connected"), .idle)
    }
    static var throughOrcaStatus: String { String(localized: "Through Orca") }
    static var throughOrcaTooltip: String {
        String(localized: "Orca reports this agent’s state, so Gitā needs no hooks of its own.")
    }
    /// Where the agent keeps its configuration, as the Install tooltip names it.
    static func home(_ tool: AgentTool) -> String { tool == .codex ? "~/.codex" : "~/.claude" }
}

@MainActor
extension SetupToolRow.Tone {
    var color: NSColor? {
        switch self {
        case .none: nil
        case .running: Theme.running
        case .idle: Theme.idle
        case .attention: Theme.needsInput
        case .success: Theme.success
        case .failure: Theme.failure
        }
    }
}

@MainActor
extension AgentConnectionState.Tone {
    var color: NSColor {
        switch self {
        case .idle: Theme.idle
        case .attention: Theme.needsInput
        case .success: Theme.success
        }
    }
}
