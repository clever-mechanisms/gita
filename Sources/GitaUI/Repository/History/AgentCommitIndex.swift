import Foundation
import GitaCore

/// Agent sessions keyed by the commit their checkout has checked out (the Status column's agent chips).
enum AgentCommitIndex {
    /// `key`: the comparable form of a path (`WindowAgents.key`).
    static func build(
        _ sessions: [AgentSession], snapshot: RepositorySnapshot, key: (URL?) -> String?
    ) -> [String: [AgentSession]] {
        let rootKey = key(snapshot.root)
        var heads: [String: String] = [:]
        for tree in snapshot.worktrees where !tree.head.isEmpty {
            if let treeKey = key(URL(fileURLWithPath: tree.path)), heads[treeKey] == nil { heads[treeKey] = tree.head }
        }
        var result: [String: [AgentSession]] = [:]
        for session in sessions {
            let checkout = key(session.checkoutRoot ?? session.workingDirectory)
            let head = checkout == rootKey ? snapshot.head : checkout.flatMap { heads[$0] }
            if let head { result[head, default: []].append(session) }
        }
        return result
    }
}
