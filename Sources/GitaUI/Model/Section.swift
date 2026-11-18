/// The pages of a repository window.
enum Section: String, CaseIterable {
    /// The pages the main window shows, in View-menu order with stable ⌥⌘1… numbers (⌘1… choose repository tabs).
    /// Settings, Activity and About are their own windows; their cases remain only for old deep links. Workflows
    /// took the next number when it split off Pull Requests, so the earlier shortcuts stay put.
    static let workspaceSections: [Self] = [.history, .changes, .worktrees, .pullRequests, .deployments, .workflows]
    case history = "History"
    case changes = "Changes"
    case worktrees = "Worktrees"
    case pullRequests = "GitHub"
    case workflows = "Workflows"
    case deployments = "Deployments"
    case agents = "Agents"
    case connections = "Connections"
    case settings = "Settings"
    case activity = "Activity"
    case about = "About"

    /// A `gita://open/<name>` (or `gita://<name>`) deep link's page: the raw value in lower case with dashes,
    /// and `pull-requests` for the GitHub page.
    init?(link name: String) {
        guard
            let section = name == "pull-requests"
                ? .pullRequests
                : Self.allCases.first(where: {
                    $0.rawValue.lowercased().replacingOccurrences(of: " ", with: "-") == name
                })
        else { return nil }
        self = section
    }

    var localizedTitle: String {
        switch self {
        case .history: String(localized: "History")
        case .changes: String(localized: "Changes")
        case .worktrees: String(localized: "Worktrees")
        case .pullRequests: String(localized: "Pull Requests")
        case .workflows: String(localized: "Workflows")
        case .deployments: String(localized: "Deployments")
        case .agents: String(localized: "Agents")
        case .connections: String(localized: "Connections")
        case .settings: String(localized: "Settings")
        case .activity: String(localized: "Activity")
        case .about: String(localized: "About")
        }
    }
    var symbol: String {
        switch self {
        case .history: "point.3.connected.trianglepath.dotted"
        case .changes: "square.and.pencil"
        case .worktrees: "arrow.triangle.branch"
        case .pullRequests: "arrow.triangle.pull"
        case .workflows: "play.circle"
        case .deployments: "triangle.fill"
        case .agents: "terminal"
        case .connections: "externaldrive.connected.to.line.below"
        case .settings: "gearshape"
        case .activity: "waveform.path"
        case .about: "info.circle"
        }
    }
}
