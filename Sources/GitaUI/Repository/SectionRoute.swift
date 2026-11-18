/// Where a requested section shows. Settings, Connections, Activity and About are windows; Worktrees & Agents is the
/// pane on the right (old deep links and notifications still name them as sections). Either way the content area
/// keeps showing the page it had.
enum SectionRoute: Equatable {
    case page(Section)
    case window(Section)
    case agentsPane

    init(_ section: Section) {
        switch section {
        case .settings, .connections, .activity, .about: self = .window(section)
        case .agents, .worktrees: self = .agentsPane
        default: self = .page(section)
        }
    }
}
