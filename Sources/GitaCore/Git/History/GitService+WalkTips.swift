import Foundation

/// The commits a history walk starts from.
///
/// `git log --topo-order` (and `--date-order`) with a commit-graph is incremental, but it first counts in-degrees
/// down to the oldest tip it was given: one old tag makes every page read the whole history (Linux, 950 tags back
/// to 2005: 0.8 s a page instead of 30 ms). Tips another tip reaches add no commit, so the walk starts from
/// `git merge-base --independent` of the scope's tips instead: the same commits, and `git log` prints the same
/// pages. Without a commit-graph that reduction itself reads the whole history (as the walk does anyway), so the
/// scope's own revisions are walked. Read-only.
extension GitService {
    /// More tips than this stay on Git's own revision arguments (the argument list must fit the process limits).
    static let walkTipLimit = 4_096

    /// The revision arguments for a `git log` over `scope`: the independent tips when a commit-graph makes finding
    /// them cheap, else `scope.revisions`. Reused while the references and HEAD stay the same.
    ///
    /// Each page pays only for what can help: no Git at all without a commit-graph, and no reference listing for a
    /// while after the reduction did not pay for this scope (thousands of independent branches).
    /// `known`: the reference listing (`GitArguments.referenceList`) and HEAD the caller just read, else read here.
    func walkRevisions(
        _ scope: HistoryScope, known: WalkTips.Known? = nil, now: ContinuousClock.Instant = .now
    ) async throws -> [String] {
        switch try await walkPlan(scope, known: known, now: now) {
        case .walk(let revisions): revisions
        case .reduce(let tips, let key): try await reduce(tips, key: key, scope: scope, now: now)
        }
    }

    /// What a walk over `scope` starts from without asking Git anything slow: known revisions, or tips still to
    /// reduce (`git merge-base --independent`, the one step that can take long: LLVM, 0.23 s).
    func walkPlan(
        _ scope: HistoryScope, known: WalkTips.Known?, now: ContinuousClock.Instant = .now
    ) async throws -> WalkTips.Plan {
        guard try await commitGraphFilePresent() else { return .walk(scope.revisions) }
        if let unhelpful = walkTipsUnhelpful, unhelpful.scope == scope, now < unhelpful.until {
            return .walk(scope.revisions)
        }
        async let graph = commitGraphState()
        async let worktrees = worktreeHeads(for: scope)
        let read: WalkTips.Known? = if let known { known } else { try await readKnown() }
        let graphState = try await graph
        guard let state = read, let otherHeads = try? await worktrees else { return .walk(scope.revisions) }
        let (references, headID) = (state.references, scope.only.isEmpty ? state.head : nil)
        let tips = WalkTips.commits(references, scope: scope, head: headID, worktreeHeads: otherHeads)
        guard graphState.present, graphState.allowed, !tips.isEmpty else { return .walk(scope.revisions) }
        guard tips.count <= Self.walkTipLimit else { return .walk(unhelpful(scope, now: now)) }
        let ancestry = objectInfoDirectory.map {
            AncestryMetadata.identity(commonDirectory: $0.deletingLastPathComponent().deletingLastPathComponent())
        }
        let key = WalkTips.Key(
            references: references, head: headID, worktreeHeads: otherHeads, scope: scope, ancestry: ancestry ?? "")
        if let cached = walkTipCache, cached.key == key { return .walk(cached.revisions) }
        guard tips.count > 1 else { return .walk(remember(tips, for: key)) }
        return .reduce(tips: tips, key: key)
    }

    /// The independent `tips`, remembered for `key`; `scope`'s own revisions when they do not reduce enough.
    func reduce(
        _ tips: [String], key: WalkTips.Key, scope: HistoryScope, now: ContinuousClock.Instant = .now
    ) async throws -> [String] {
        let reduced = try await execute(
            ["merge-base", "--independent"] + tips, timeout: 10, outputLimit: 1_024 * 1_024, allowFailure: true)
        let independent = reduced.exitCode == 0 ? WalkTips.independent(reduced.stdout, of: tips) : []
        // A reduction that failed, or did not pay, is not tried again for every page.
        guard !independent.isEmpty, WalkTips.worthWalking(independent, of: tips) else {
            return unhelpful(scope, now: now)
        }
        return remember(independent, for: key)
    }

    /// The reduction did not pay for `scope`: its revisions are walked as they are for `WalkTips.unhelpfulFor`.
    private func unhelpful(_ scope: HistoryScope, now: ContinuousClock.Instant) -> [String] {
        walkTipsUnhelpful = (scope, now + WalkTips.unhelpfulFor)
        return scope.revisions
    }

    /// Nil when the references cannot be listed: the walk then keeps Git's own arguments rather than starting from
    /// HEAD alone.
    private func readKnown() async throws -> WalkTips.Known? {
        async let listing = execute(GitArguments.referenceList, allowFailure: true)
        async let head = headCommit()
        let (references, headID) = try await (listing, head)
        return references.exitCode == 0 ? WalkTips.Known(references: references.stdout, head: headID) : nil
    }

    /// The HEAD commit of every worktree when `scope` walks HEAD: `--all` walks from the other worktrees' HEADs as
    /// well, a detached one included, which no reference names. Throws when Git cannot list them.
    private func worktreeHeads(for scope: HistoryScope) async throws -> [String] {
        guard scope.only.isEmpty else { return [] }
        let list = try await execute(["worktree", "list", "--porcelain", "-z"])
        return GitParsers.worktrees(list.stdout).map(\.head).filter(GitParsers.isObjectID)
    }

    private func remember(_ revisions: [String], for key: WalkTips.Key) -> [String] {
        walkTipCache = WalkTips.Cache(key: key, revisions: revisions)
        return revisions
    }
}

/// Parsing and caching for `GitService.walkRevisions`. Pure, so every rule is tested without Git.
enum WalkTips {
    /// Starting from thousands of explicit tips costs Git more than `--all` does (VS Code: 5 604 of 6 269 tips stay
    /// independent, 159 ms against 108 ms); the reduction pays when it leaves a few or removes most.
    static let fewTips = 256
    /// How long a scope whose reduction did not pay keeps Git's own arguments before it is tried again.
    static let unhelpfulFor = Duration.seconds(300)

    /// Whether walking from `independent` beats walking from all of `tips`.
    static func worthWalking(_ independent: [String], of tips: [String]) -> Bool {
        independent.count <= fewTips || independent.count * 2 <= tips.count
    }

    /// Where a walk starts: revisions ready to walk, or tips to reduce first.
    enum Plan: Sendable {
        case walk([String])
        case reduce(tips: [String], key: Key)
    }

    /// A reference listing and HEAD, read together.
    struct Known: Sendable {
        var references: Data
        var head: String?
    }

    struct Key: Equatable, Sendable {
        var references: Data
        var head: String?
        var worktreeHeads: [String]
        var scope: HistoryScope
        /// Shallow boundaries and grafts change which tips reach which.
        var ancestry: String

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.head == rhs.head && lhs.worktreeHeads == rhs.worktreeHeads && lhs.scope == rhs.scope
                && lhs.ancestry == rhs.ancestry && lhs.references == rhs.references
        }
    }

    struct Cache {
        var key: Key
        var revisions: [String]
    }

    static func hasCommitGraph(in objectInfo: URL) -> Bool {
        let manager = FileManager.default
        return manager.fileExists(atPath: objectInfo.appendingPathComponent("commit-graph").path)
            || manager.fileExists(atPath: objectInfo.appendingPathComponent("commit-graphs/commit-graph-chain").path)
    }

    /// The commits `scope` starts from, in `--all`'s order without repeats: every reference that is not hidden, or
    /// only the chosen ones; then, unless only chosen references are walked, HEAD and every worktree's HEAD. Git
    /// takes tips with the same commit date in the order given, so the order keeps the pages of the two walks the
    /// same. Empty when there is nothing to walk or a reference cannot be reduced here (a tag of a tag): the walk
    /// then keeps Git's own arguments.
    static func commits(
        _ listing: Data, scope: HistoryScope, head: String?, worktreeHeads: [String] = []
    ) -> [String] {
        let fields = GitOutput.nulFields(listing)
        let chosen = Set(scope.only)
        let hidden = Set(scope.hidden)
        var tips: [String] = []
        var seen = Set<String>()
        func add(_ id: String) {
            if seen.insert(id).inserted { tips.append(id) }
        }
        if chosen.isEmpty, let head, !GitParsers.isObjectID(head) { return [] }
        var index = 0
        while index + 5 < fields.count {
            // `GitArguments.referenceList`: name, object, HEAD marker, peeled object, type, peeled type.
            let name = fields[index].trimmingCharacters(in: .newlines)
            let (object, peeled, type, peeledType) = (
                fields[index + 1], fields[index + 3], fields[index + 4], fields[index + 5]
            )
            index += 6
            guard chosen.isEmpty ? !hidden.contains(name) : chosen.contains(name) else { continue }
            switch (type, peeledType) {
            case ("commit", _): add(object)
            case ("tag", "commit"): add(peeled)
            case ("tag", "tag"): return []
            default: continue // a tree or blob: `git log` walks no commit from it
            }
        }
        if chosen.isEmpty {
            if let head { add(head) }
            worktreeHeads.forEach(add)
        }
        return tips.allSatisfy(GitParsers.isObjectID) ? tips : []
    }

    /// `git merge-base --independent` output: one object ID per line, each one of `tips`, in `tips` order (the
    /// walk then starts from the same tips in the same order whatever Git printed first). Empty when it is not that.
    static func independent(_ output: Data, of tips: [String]) -> [String] {
        let kept = Set(String(decoding: output, as: UTF8.self).split(separator: "\n").map(String.init))
        return kept.isSubset(of: tips) ? tips.filter(kept.contains) : []
    }
}
