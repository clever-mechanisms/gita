import GitaCore

/// Commits reachable from HEAD but from no remote branch, capped at the branch's ahead count (the Status column's
/// "Not pushed" chips). Walked again only when HEAD, the ahead count, the loaded commits or a remote tip moves.
struct UnpushedCommits {
    private(set) var ids = Set<String>()
    private var identity: Identity?

    private struct Identity: Equatable {
        var head: String
        var ahead: Int
        var commits: Int
        var remoteTips: [String]

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.head == rhs.head && lhs.ahead == rhs.ahead && lhs.commits == rhs.commits
                && lhs.remoteTips == rhs.remoteTips
        }
    }

    /// Updates for `snapshot`; true when the set changed.
    @discardableResult
    mutating func update(_ snapshot: RepositorySnapshot?) -> Bool {
        let previous = ids
        guard let snapshot, snapshot.ahead > 0, let head = snapshot.head else {
            ids = []
            identity = nil
            return previous != ids
        }
        let remoteTips = snapshot.references.filter { $0.kind == .remote }.map(\.commit)
        let next = Identity(head: head, ahead: snapshot.ahead, commits: snapshot.commits.count, remoteTips: remoteTips)
        guard next != identity else { return false }
        identity = next
        ids = Self.walk(snapshot.commits, from: head, remoteTips: remoteTips, limit: snapshot.ahead)
        return previous != ids
    }

    static func walk(_ commits: [GitCommit], from head: String, remoteTips: [String], limit: Int) -> Set<String> {
        var parents: [String: [String]] = [:]
        parents.reserveCapacity(commits.count)
        for commit in commits { parents[commit.id] = commit.parents }
        var remote = Set<String>()
        var stack = remoteTips
        while let id = stack.popLast() {
            guard remote.insert(id).inserted, let next = parents[id] else { continue }
            stack.append(contentsOf: next)
        }
        var result = Set<String>()
        stack = [head]
        while let id = stack.popLast(), result.count < limit {
            guard !remote.contains(id), !result.contains(id), let next = parents[id] else { continue }
            result.insert(id)
            stack.append(contentsOf: next)
        }
        return result
    }
}
