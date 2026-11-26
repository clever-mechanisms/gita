import Foundation

public struct BranchStackTopologyInput: Sendable {
    public let branches: [GitReference]
    public let base: GitReference
    /// Topological order, newest first. A shared history prefix may be represented by a single root.
    public let commits: [GitCommit]

    public init(branches: [GitReference], base: GitReference, commits: [GitCommit]) {
        self.branches = branches
        self.base = base
        self.commits = commits
    }
}

public enum BranchStackDetector {
    public static func detect(
        _ input: BranchStackTopologyInput, includeSingleLayerBranches: Bool = false
    )
        -> [BranchStack]
    {
        let graph = StackGraph(input.commits)
        guard let baseIndex = graph.index(for: input.base.commit) else { return [] }
        let baseHistory = graph.ancestors(from: baseIndex)
        var tips: [String: StackTip] = [:]
        for ref in input.branches where ref.kind == .branch {
            guard let tipIndex = graph.index(for: ref.commit), !baseHistory.contains(tipIndex) else { continue }
            let history = graph.ancestors(from: tipIndex)
            guard !history.isDisjoint(with: baseHistory) else { continue }
            tips[ref.name] = StackTip(
                ref: ref, commitIndex: tipIndex, history: history,
                ahead: history.subtractingCount(baseHistory), behind: baseHistory.subtractingCount(history))
        }
        let byCommit = Dictionary(
            tips.values.map { ($0.commitIndex, $0) },
            uniquingKeysWith: { lhs, rhs in lhs.ref.name < rhs.ref.name ? lhs : rhs })
        let parents = tips.compactMapValues { $0.closestParent(in: byCommit) }
        let builder = StackBuilder(
            tips: tips, parents: parents, base: input.base, baseHistory: baseHistory, graph: graph)
        let leaves = Set(tips.keys).subtracting(parents.values)
        return leaves.sorted().compactMap { builder.stack(endingAt: $0, includeSingle: includeSingleLayerBranches) }
    }
}

private struct StackBuilder {
    let tips: [String: StackTip]
    let parents: [String: String]
    let base: GitReference
    let baseHistory: CommitBitSet
    let graph: StackGraph

    func stack(endingAt leaf: String, includeSingle: Bool) -> BranchStack? {
        var chain: [StackTip] = []
        var next = tips[leaf]
        while let tip = next {
            chain.append(tip)
            next = parents[tip.ref.name].flatMap { tips[$0] }
        }
        guard includeSingle || chain.count >= 2 else { return nil }
        var history = baseHistory
        let layers = chain.reversed().enumerated().map { index, tip in
            let subjects = graph.subjects(in: tip.history, excluding: history)
            let position = StackLayer.Position(depth: index + 1, aheadOfBase: tip.ahead, behindBase: tip.behind)
            history = tip.history
            return StackLayer(reference: tip.ref, position: position, commitSubjects: subjects)
        }
        return BranchStack(
            baseBranch: base.name, baseCommitID: base.commit, layers: layers,
            isBaseCurrent: base.isCurrent, baseFullName: base.fullName)
    }
}

private struct StackTip {
    let ref: GitReference
    let commitIndex: Int
    let history: CommitBitSet
    let ahead: Int
    let behind: Int

    func closestParent(in tips: [Int: Self]) -> String? {
        let sharedWithBase = history.count - ahead
        var best: Self?
        for (index, candidate) in tips where index != commitIndex && history.contains(index) {
            guard candidate.history.count > sharedWithBase else { continue }
            if let current = best {
                let closer =
                    candidate.history.count == current.history.count
                    ? candidate.ref.name < current.ref.name
                    : candidate.history.count > current.history.count
                if closer { best = candidate }
            } else {
                best = candidate
            }
        }
        return best?.ref.name
    }
}

private struct StackGraph {
    let commits: [GitCommit]
    let indices: [String: Int]
    let parents: [[Int]]
    let nodeCount: Int

    init(_ commits: [GitCommit]) {
        self.commits = commits
        var map: [String: Int] = [:]
        map.reserveCapacity(commits.count + 1)
        for (offset, commit) in commits.enumerated() where map[commit.id] == nil { map[commit.id] = offset }
        var nextIndex = commits.count
        var adjacency: [[Int]] = []
        adjacency.reserveCapacity(commits.count)
        for commit in commits {
            var parentIndices: [Int] = []
            for parent in commit.parents {
                if let existing = map[parent] {
                    parentIndices.append(existing)
                } else {
                    map[parent] = nextIndex
                    parentIndices.append(nextIndex)
                    nextIndex += 1
                }
            }
            adjacency.append(parentIndices)
        }
        indices = map
        parents = adjacency
        nodeCount = nextIndex
    }

    func index(for id: String) -> Int? { indices[id] }

    func ancestors(from start: Int) -> CommitBitSet {
        var seen = CommitBitSet(capacity: nodeCount)
        var pending = [start]
        while let current = pending.popLast() {
            guard seen.insert(current) else { continue }
            if current < parents.count { pending.append(contentsOf: parents[current]) }
        }
        return seen
    }

    func subjects(in included: CommitBitSet, excluding excluded: CommitBitSet) -> [String] {
        var result: [String] = []
        for index in commits.indices where included.contains(index) && !excluded.contains(index) {
            result.append(commits[index].subject)
        }
        return result
    }
}

private struct CommitBitSet {
    private var words: [UInt64]
    private(set) var count = 0

    init(capacity: Int) { words = Array(repeating: 0, count: max(1, (capacity + 63) / 64)) }

    func contains(_ index: Int) -> Bool {
        let word = index >> 6
        return word < words.count && (words[word] & (UInt64(1) << (index & 63))) != 0
    }

    @discardableResult mutating func insert(_ index: Int) -> Bool {
        let word = index >> 6
        let mask = UInt64(1) << (index & 63)
        if (words[word] & mask) != 0 { return false }
        words[word] |= mask
        count += 1
        return true
    }

    func isDisjoint(with other: Self) -> Bool {
        for index in words.indices where (words[index] & other.words[index]) != 0 { return false }
        return true
    }

    func subtractingCount(_ other: Self) -> Int {
        var total = 0
        for index in words.indices { total += (words[index] & ~other.words[index]).nonzeroBitCount }
        return total
    }
}
