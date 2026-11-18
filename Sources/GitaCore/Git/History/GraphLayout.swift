import Foundation

/// One compact row per commit. Only active ancestry is retained, not an edge matrix.
/// Coordinates are lane indexes: incoming top → center, outgoing center → bottom.
///
/// Colour follows the branch, not the column: a lane's colour is carried down its first-parent chain, and a commit
/// that reaches its first parent through a lane opened by a merge (a second-parent claim) takes that lane over with
/// its own colour. Without that, a branch whose parent was merged elsewhere first would hand its column to the
/// merged-in parent and appear to change colour midway.
public enum GraphLayout {
    fileprivate struct Lane: Sendable {
        var hash: String
        var color: Int
        /// Opened by a first-parent child (or a branch tip): this lane is that branch's own line.
        var firstParent: Bool
    }

    /// Lanes still open after the last laid-out row: a row depends only on the rows above it, so a further history
    /// page continues from here instead of laying out every loaded commit again.
    public struct State: Sendable {
        fileprivate var active: [Lane] = []
        fileprivate var nextColor = 0
        public init() {}
    }

    public static func build(commits: [GitCommit]) -> [GraphRow] { build(commits: commits, continuing: State()).rows }

    public static func build(commits: [GitCommit], continuing state: State) -> (rows: [GraphRow], state: State) {
        var state = state
        var rows: [GraphRow] = []
        rows.reserveCapacity(commits.count)
        for commit in commits { rows.append(state.place(commit)) }
        return (rows, state)
    }
}

extension GraphLayout.State {
    /// Lays out one commit below the rows placed so far.
    fileprivate mutating func place(_ commit: GitCommit) -> GraphRow {
        let existing = active.firstIndex { $0.hash == commit.id }
        let lane = existing ?? openLane(for: commit.id)
        let color = active[lane].color
        let incoming = active.indices.compactMap { index -> GraphEdge? in
            guard index != lane || existing != nil else { return nil }
            return GraphEdge(from: index, to: index, color: active[index].color)
        }
        var after = active
        after.remove(at: lane)
        assignParents(commit.parents, color: color, from: lane, into: &after)
        let outgoing = outgoingEdges(commit, lane: lane, color: color, after: after)
        active = after
        return GraphRow(lane: lane, color: color, incoming: incoming, outgoing: outgoing)
    }

    private mutating func openLane(for hash: String) -> Int {
        active.append(GraphLayout.Lane(hash: hash, color: nextColor, firstParent: true))
        nextColor += 1
        return active.count - 1
    }

    private mutating func assignParents(
        _ parents: [String], color: Int, from lane: Int, into after: inout [GraphLayout.Lane]
    ) {
        var insertion = min(lane, after.count)
        for (parentNumber, parent) in parents.enumerated() {
            if let pending = after.firstIndex(where: { $0.hash == parent }) {
                guard parentNumber == 0 else { continue }
                if pending >= insertion {
                    // The parent's lane is to the right: this branch keeps its column and colour, and that lane
                    // folds into it (a merge line or a later fork joining this line).
                    after.remove(at: pending)
                    after.insert(GraphLayout.Lane(hash: parent, color: color, firstParent: true), at: insertion)
                    insertion += 1
                } else if !after[pending].firstParent {
                    // To the left but only reached by a merge so far: from here on it is this branch's line.
                    after[pending].color = color
                    after[pending].firstParent = true
                }
                continue
            }
            let parentColor = parentNumber == 0 ? color : takeColor()
            after.insert(
                GraphLayout.Lane(hash: parent, color: parentColor, firstParent: parentNumber == 0),
                at: min(insertion, after.count))
            insertion += 1
        }
    }

    private mutating func takeColor() -> Int {
        defer { nextColor += 1 }
        return nextColor
    }

    private func outgoingEdges(_ commit: GitCommit, lane: Int, color: Int, after: [GraphLayout.Lane]) -> [GraphEdge] {
        // A malformed history can list one parent twice; the first lane wins instead of trapping.
        let destinations = Dictionary(after.enumerated().map { ($0.element.hash, $0.offset) }) { first, _ in first }
        var outgoing: [GraphEdge] = []
        for (index, carry) in active.enumerated() where index != lane {
            if let destination = destinations[carry.hash] {
                outgoing.append(GraphEdge(from: index, to: destination, color: carry.color))
            }
        }
        for (parentNumber, parent) in commit.parents.enumerated() {
            if let destination = destinations[parent] {
                outgoing.append(
                    GraphEdge(from: lane, to: destination, color: parentNumber == 0 ? color : after[destination].color))
            }
        }
        return outgoing
    }
}
