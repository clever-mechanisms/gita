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
    case storage = "Storage"
    case submodulesLFS = "Submodules and LFS"
    case cleanup = "Cleanup"
    case stackedBranches = "Stacked Branches"
    case reflog = "Reflog"
    case codeSearch = "Code Search"
    case lineHistory = "Line History"
    case commitBuckets = "Commit Buckets"
    case collisionRadar = "Collision Radar"
    case flightRecorder = "Flight Recorder"
    case agentArena = "Agent Arena"
    case visualPreviewDiff = "Visual Preview Diff"

    var isToolPage: Bool {
        switch self {
        case .storage, .submodulesLFS, .cleanup, .stackedBranches, .reflog, .codeSearch, .lineHistory,
            .commitBuckets, .collisionRadar, .flightRecorder, .agentArena, .visualPreviewDiff:
            true
        default:
            false
        }
    }

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
        toolTitle ?? primaryTitle
    }

    private var primaryTitle: String {
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
        default: String(localized: "About")
        }
    }

    private var toolTitle: String? {
        switch self {
        case .storage: String(localized: "Storage & Health")
        case .submodulesLFS: String(localized: "Submodules & Git LFS")
        case .cleanup: String(localized: "Branch & Worktree Cleanup")
        case .stackedBranches: String(localized: "Stacked Branches")
        case .reflog: String(localized: "Reflog")
        case .codeSearch: String(localized: "Code Search")
        case .lineHistory: String(localized: "Line History")
        case .commitBuckets: String(localized: "Organize into Commits")
        case .collisionRadar: String(localized: "Collision Radar")
        case .flightRecorder: String(localized: "Agent Flight Recorder")
        case .agentArena: String(localized: "Fork & Race Arena")
        case .visualPreviewDiff: String(localized: "Visual Preview Diff")
        default: nil
        }
    }

    var symbol: String {
        toolSymbol ?? primarySymbol
    }

    private var primarySymbol: String {
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
        default: "info.circle"
        }
    }

    private var toolSymbol: String? {
        switch self {
        case .storage: "internaldrive"
        case .submodulesLFS: "shippingbox"
        case .cleanup: "wand.and.stars"
        case .stackedBranches: "square.stack.3d.up"
        case .reflog: "clock.arrow.circlepath"
        case .codeSearch: "doc.text.magnifyingglass"
        case .lineHistory: "text.line.first.and.arrowtriangle.forward"
        case .commitBuckets: "square.stack.3d.forward.dottedline"
        case .collisionRadar: "dot.radiowaves.left.and.right"
        case .flightRecorder: "waveform.path.ecg"
        case .agentArena: "flag.checkered.2.crossed"
        case .visualPreviewDiff: "rectangle.split.2x1"
        default: nil
        }
    }
}
