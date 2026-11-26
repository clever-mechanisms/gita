import Foundation

public actor SpeculativeGitService {
    let gitService: GitService
    private struct RebaseCacheKey: Hashable {
        let baseTreeID: String
        let planHash: String
    }
    private struct MergeKey: Hashable {
        let ours: String
        let theirs: String
    }
    private var rebases: SpeculativeLRUCache<RebaseCacheKey, RebaseSimulationResult>
    private var merges: SpeculativeLRUCache<MergeKey, PairwiseMergeOutcome>

    public init(gitService: GitService, cacheCapacity: Int = 64) {
        self.gitService = gitService
        rebases = .init(capacity: cacheCapacity)
        merges = .init(capacity: cacheCapacity)
    }

    public func clearCache() {
        rebases.removeAll()
        merges.removeAll()
    }

    public func simulateRebase(onto: String, steps: [GitRebaseStep]) async throws -> RebaseSimulationResult {
        let commit = try await gitService.resolveCommit(onto, verify: true)
        let base = try await tree(of: commit)
        let key = RebaseCacheKey(baseTreeID: base, planHash: PlanFingerprint.hash(baseTree: base, steps: steps))
        // A symbolic step can move between requests, even when the destination tree is unchanged.
        let cacheable = steps.allSatisfy { GitParsers.isObjectID($0.commitID) }
        if cacheable, var cached = rebases.value(for: key) {
            cached.ontoCommit = commit
            return cached
        }
        var current = base
        var predictions: [RebaseStepPrediction] = []
        for step in steps {
            try Task.checkCancellation()
            let prediction = try await predict(step, onto: current)
            current = prediction.resultingTreeID ?? current
            predictions.append(prediction)
        }
        let result = RebaseSimulationResult(
            ontoCommit: commit, baseTreeID: base, steps: predictions, finalTreeID: current)
        if cacheable { rebases.insert(result, for: key) }
        return result
    }

    private func predict(_ step: GitRebaseStep, onto current: String) async throws -> RebaseStepPrediction {
        if step.action == .drop {
            return .init(commitID: step.commitID, action: .drop, outcome: .dropped, resultingTreeID: current)
        }
        let sha = try await gitService.resolveCommit(step.commitID)
        let outcome = try await replay(commit: sha, onto: current)
        return .init(
            commitID: step.commitID, action: step.action, outcome: outcome.replay(onto: current),
            resultingTreeID: outcome.treeID)
    }

    private func tree(of commit: String) async throws -> String {
        try await gitService.bucketObjectID(["rev-parse", "--verify", "--end-of-options", commit + "^{tree}"])
    }

    private func replay(commit: String, onto: String) async throws -> PairwiseMergeOutcome {
        let result = try await gitService.execute(["rev-list", "--parents", "-n", "1", commit])
        let fields = result.text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.first == commit, fields.allSatisfy(GitParsers.isObjectID) else { throw GitError.invalidReference }
        guard fields.count <= 2 else {
            return .unsupported(reason: String(localized: "Merge commits cannot be simulated in linear rebase."))
        }
        let base: String
        if fields.count == 2 {
            base = fields[1]
        } else if commit.count == 40 {
            base = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
        } else {
            base = try await gitService.bucketObjectID(["hash-object", "-t", "tree", "--", "/dev/null"])
        }
        return try await merge(ours: onto, theirs: commit, base: base)
    }

    private func merge(ours: String, theirs: String, base: String? = nil) async throws -> PairwiseMergeOutcome {
        let arguments =
            ["merge-tree", "--write-tree", "-z", "--name-only", "--messages"]
            + (base.map { ["--merge-base=" + $0] } ?? []) + [ours, theirs]
        return try await MergeTreeOutputParser.parse(gitService.execute(arguments, allowFailure: true))
    }

    public func checkPairwiseMerge(ours: String, theirs: String) async throws -> PairwiseMergePrediction {
        let first = try await gitService.resolveCommit(ours, verify: true)
        let second = try await gitService.resolveCommit(theirs, verify: true)
        let key = MergeKey(ours: first, theirs: second)
        let outcome: PairwiseMergeOutcome
        if let cached = merges.value(for: key) {
            outcome = cached
        } else {
            outcome = try await merge(ours: first, theirs: second)
            merges.insert(outcome, for: key)
        }
        return .init(oursRef: ours, theirsRef: theirs, oursCommitID: first, theirsCommitID: second, outcome: outcome)
    }

    public func checkCherryPick(commit: String, onto: String = "HEAD") async throws -> PreFlightPrediction {
        let target = try await gitService.resolveCommit(commit, verify: true)
        let destination = try await gitService.resolveCommit(onto, verify: true)
        let outcome = try await replay(commit: target, onto: destination)
        return try await .init(
            kind: .cherryPick, targetRef: commit, ontoRef: onto,
            outcome: outcome.replay(onto: tree(of: destination)), treeID: outcome.treeID)
    }

    public func checkStashApply(stashRef: String, onto: String = "HEAD") async throws -> PreFlightPrediction {
        let target = try await gitService.resolveCommit(stashRef, verify: true)
        let base = try await gitService.resolveCommit(target + "^1", verify: true)
        let destination = try await gitService.resolveCommit(onto, verify: true)
        let outcome = try await merge(ours: destination, theirs: target, base: base)
        return try await .init(
            kind: .stash, targetRef: stashRef, ontoRef: onto,
            outcome: outcome.replay(onto: tree(of: destination)), treeID: outcome.treeID)
    }
}

extension GitService {
    func bucketObjectID(_ arguments: [String]) async throws -> String {
        try Self.speculativeObjectID(await execute(arguments))
    }

    static func speculativeObjectID(_ result: CommandResult) throws -> String {
        let id = GitOutput.withoutTerminalLF(result.text)
        guard GitParsers.isObjectID(id) else { throw GitError.invalidReference }
        return id
    }
}

enum MergeTreeOutputParser {
    static func parse(_ result: CommandResult) throws -> PairwiseMergeOutcome {
        guard result.exitCode == 0 || result.exitCode == 1 else {
            return .unsupported(reason: GitService.failure(result).localizedDescription)
        }
        let fields = result.text.components(separatedBy: "\0")
        guard fields.count >= 2, let tree = fields.first, GitParsers.isObjectID(tree) else {
            throw GitError.invalidReference
        }
        if result.exitCode == 0 { return .clean(treeID: tree) }
        let rest = fields.dropFirst()
        guard let separator = rest.firstIndex(of: "") else { throw GitError.invalidReference }
        var messages = rest.suffix(from: separator + 1)[...]
        var details: [String] = []
        while let field = messages.first, !field.isEmpty {
            guard let paths = Int(field), paths >= 0, messages.count >= 3, paths <= messages.count - 3 else {
                throw GitError.invalidReference
            }
            details.append(messages[messages.startIndex + paths + 2])
            messages = messages.dropFirst(paths + 3)
        }
        return .conflict(treeID: tree, files: Array(rest[..<separator]), details: details.joined())
    }
}
