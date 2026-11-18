import Foundation
import GitaCore

/// Pure: the pane's rows, filter, text query and repository order → the groups it lists.
@MainActor
enum AgentsPaneLayout {
    struct Group: Equatable {
        let title: String
        let isCurrent: Bool
        let rows: [AgentsPaneView.Row]
    }

    /// The open repository first, then the others by `order`: Status (the group's most urgent row; equal ones by
    /// name) or Name. Within a group, most urgent first, otherwise in the given order.
    static func groups(
        _ rows: [AgentsPaneView.Row], filter: AgentsPaneView.StateFilter, query: String, order: RepositoryListOrder
    ) -> [Group] {
        let visible = rows.filter { filter.matches($0) && matches($0, query: query) }
        var keys: [String] = []
        var grouped: [String: [AgentsPaneView.Row]] = [:]
        for row in visible.sorted(by: { $0.isCurrentRepository && !$1.isCurrentRepository }) {
            let key = row.repositoryRoot.path
            if grouped[key] == nil { keys.append(key) }
            grouped[key, default: []].append(row)
        }
        let current = keys.prefix { grouped[$0]?.first?.isCurrentRepository == true }
        let others = order.sorted(
            Array(keys.dropFirst(current.count)), name: { grouped[$0]?.first?.repositoryName ?? $0 },
            rank: { grouped[$0]?.map(\.urgency).min() ?? AgentState.byUrgency.count })
        return (Array(current) + others).compactMap { key in
            guard let members = grouped[key], let first = members.first else { return nil }
            let ordered = members.enumerated().sorted {
                ($0.element.urgency, $0.offset) < ($1.element.urgency, $1.offset)
            }
            return Group(
                title: first.repositoryName, isCurrent: first.isCurrentRepository,
                rows: ordered.map(\.element))
        }
    }

    /// The query in the repository, worktree, branch or agent line; an empty query matches everything.
    static func matches(_ row: AgentsPaneView.Row, query: String) -> Bool {
        query.isEmpty
            || [row.repositoryName, row.treeName, row.branch, row.session.map { WindowAgents.line($0) } ?? ""]
                .contains { $0.localizedStandardContains(query) }
    }
}
