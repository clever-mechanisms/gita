import Foundation
import GitaCore

extension AgentsPaneView {
    /// One checkout in the pane: its agent session if one works there, and what the window knows about it.
    struct Row: Equatable {
        var id: String
        var session: AgentSession?
        var repositoryName: String
        var repositoryRoot: URL
        var checkoutPath: String
        var treeName: String
        var branch: String
        var ahead = 0
        var changed = 0
        var isCurrentRepository = false
        /// This window shows this very checkout (opening it in a tab would only switch to History).
        var isOpenHere = false
        var isMainCheckout = true
        var pullRequest: ProviderItem?
        var checks: [ProviderItem] = []
        var preview: ProviderItem?
        var subagents: [AgentSession] = []
        /// The checkout's name in the list: the worktree folder, else the repository.
        var name: String { treeName.isEmpty ? repositoryName : treeName }
        /// Most urgent first; checkouts without an agent last.
        var urgency: Int { AgentState.urgency(session?.state) }
    }

    /// The pane's state filter: everything, one agent state, or checkouts without an agent.
    enum StateFilter: Equatable {
        case all
        case state(AgentState)
        case noAgent

        static let choices: [Self] = [.all] + AgentState.byUrgency.map(Self.state) + [.noAgent]

        func matches(_ row: Row) -> Bool {
            switch self {
            case .all: true
            case .state(let state): row.session?.state == state
            case .noAgent: row.session == nil
            }
        }

        func count(in rows: [Row]) -> Int { rows.filter(matches).count }

        var title: String {
            switch self {
            case .all: String(localized: "All")
            case .state(let state): state.localizedTitle
            case .noAgent: String(localized: "Worktrees without an agent")
            }
        }
    }
}
