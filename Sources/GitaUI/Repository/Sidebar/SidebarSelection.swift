/// The sidebar row shown selected: a page (Local Changes, Pull Requests…), All Commits, a reference or a stash.
enum SidebarSelection: Hashable {
    case history, changes, pullRequests, workflows, deployments, storage
    /// The agents and worktrees pages, which have no row of their own.
    case agents
    case reference(fullName: String)
    case stash(ref: String)

    /// The row for a page other than History (nil: History, whose row follows what the history shows).
    init?(page section: Section) {
        switch section {
        case .changes: self = .changes
        case .pullRequests: self = .pullRequests
        case .workflows: self = .workflows
        case .deployments: self = .deployments
        case .agents, .worktrees: self = .agents
        default: return nil
        }
    }

    /// The page a navigation row opens (nil: All Commits, which shows History).
    var section: Section? {
        switch self {
        case .changes: .changes
        case .pullRequests: .pullRequests
        case .workflows: .workflows
        case .deployments: .deployments
        default: nil
        }
    }
}
