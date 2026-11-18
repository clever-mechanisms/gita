import Foundation

/// One author's commits as a graph of their own: each commit keeps its real parents (details, diffs and merges stay
/// true), and `graphParents` links it to the nearest earlier commits by the same author on each path, skipping
/// everyone else's work in between. Git keeps no such links (`--author` only hides commits), so they are worked
/// out from the commit graph walked in the same order.
public struct AuthorHistory: Sendable, Equatable {
    public var commits: [GitCommit]
    public var graphParents: [String: [String]]
    public var hasMore: Bool
    public init(commits: [GitCommit] = [], graphParents: [String: [String]] = [:], hasMore: Bool = false) {
        self.commits = commits
        self.graphParents = graphParents
        self.hasMore = hasMore
    }

    /// Links from `structure` (every walked commit and its parents, children before parents) for the commits in
    /// `authored`: through each real parent, the nearest authored commit down that parent's first-parent line (the
    /// branch it was made on). One link per parent at most, each a true ancestor; one pass, newest last. A link that
    /// the commit's other link already reaches is dropped.
    static func links(structure: [(id: String, parents: [String])], authored: Set<String>) -> [String: [String]] {
        // Oldest first, so a commit's first parent is resolved before it.
        var nearest: [String: String] = [:]
        nearest.reserveCapacity(structure.count)
        for (id, parents) in structure.reversed() {
            if authored.contains(id) {
                nearest[id] = id
            } else if let first = parents.first, let below = nearest[first] {
                nearest[id] = below
            }
        }
        var links: [String: [String]] = [:]
        for (id, parents) in structure where authored.contains(id) {
            var targets: [String] = []
            for parent in parents {
                if let target = nearest[parent], target != id, !targets.contains(target) { targets.append(target) }
            }
            if !targets.isEmpty { links[id] = targets }
        }
        // Only the author's own merges have two links; drop one the other already reaches.
        for (id, targets) in links where targets.count > 1 {
            links[id] = targets.filter { candidate in
                !targets.contains { other in other != candidate && reaches(from: other, to: candidate, in: links) }
            }
        }
        return links
    }
    private static func reaches(from start: String, to target: String, in links: [String: [String]]) -> Bool {
        var stack = [start]
        var seen: Set<String> = []
        var steps = 0
        while let id = stack.popLast(), steps < 2_000 {
            steps += 1
            if id == target { return true }
            guard seen.insert(id).inserted else { continue }
            stack.append(contentsOf: links[id] ?? [])
        }
        return false
    }
}
