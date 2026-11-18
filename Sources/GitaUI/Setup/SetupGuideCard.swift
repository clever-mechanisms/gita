import Foundation

/// The Setup Guide's steps, in order: what Gita is, then what it shows and where it reads it, the tools it needs and
/// where to find it afterwards.
enum SetupGuideCard: Int, CaseIterable {
    case welcome, history, integrations, agents, tools, ready

    var identifier: String {
        switch self {
        case .welcome: "welcome"
        case .history: "history"
        case .integrations: "integrations"
        case .agents: "agents"
        case .tools: "tools"
        case .ready: "ready"
        }
    }
    /// The step's name in the rail.
    var title: String {
        switch self {
        case .welcome: String(localized: "Welcome")
        case .history: String(localized: "History")
        case .integrations: String(localized: "Integrations")
        case .agents: String(localized: "Agents")
        case .tools: String(localized: "Tools")
        case .ready: String(localized: "Ready")
        }
    }
    var heading: String {
        switch self {
        case .welcome: String(localized: "Welcome to Gitā")
        case .history: String(localized: "Every branch, one graph")
        case .integrations: String(localized: "Pull requests, checks and previews")
        case .agents: String(localized: "Coding agents at work")
        case .tools: String(localized: "What Gitā uses on this Mac")
        case .ready: String(localized: "You’re ready")
        }
    }
    var subtitle: String {
        switch self {
        case .welcome:
            String(
                localized:
                    """
                    A fast Git client for work spread across worktrees, tools and coding agents. Choose what it \
                    shows; change anything later in Settings.
                    """
            )
        case .history:
            String(localized: "Merges fold away their commits until you open them, so long histories stay readable.")
        case .integrations:
            String(
                localized:
                    "Gitā reads GitHub and Vercel through the CLIs you already use. It stores no account and no token.")
        case .agents:
            String(localized: "See which agent works where, and which one waits for you, next to its branch.")
        case .tools:
            String(
                localized: "Install or sign in where something is missing. Nothing changes until you press a button.")
        case .ready:
            String(
                localized: "Gitā lives in the menu bar too: your repositories, agents and checks are one click away.")
        }
    }
    var symbol: String {
        switch self {
        case .welcome: "hand.wave"
        case .history: "point.3.connected.trianglepath.dotted"
        case .integrations: "puzzlepiece.extension"
        case .agents: "terminal"
        case .tools: "wrench.and.screwdriver"
        case .ready: "checkmark.seal"
        }
    }
}
