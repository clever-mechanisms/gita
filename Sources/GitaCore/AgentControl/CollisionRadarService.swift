import Foundation

public actor CollisionRadarService {
    private typealias Parser = CollisionRadarDiffParser
    private let runner: any CommandRunning

    public init(runner: any CommandRunning = CommandRunner()) { self.runner = runner }

    public func scan(repositoryRoot: URL) async throws -> CollisionRadarReport {
        let git = AgentControlGit(root: repositoryRoot, runner: runner)
        let listing = try await git.run(["worktree", "list", "--porcelain", "-z"])
        let trees = GitParsers.worktrees(listing.stdout).filter { !$0.isBare && !$0.isPrunable }
        var pairs: [WorktreeCollisionPair] = []
        var remaining = 20
        for (index, source) in trees.enumerated() {
            for target in trees.dropFirst(index + 1) {
                if let pair = try await inspect(source, target, git: git) { pairs.append(pair) }
                remaining -= 1
                if remaining == 0 { break }
            }
            if remaining == 0 { break }
        }
        return CollisionRadarReport(repositoryRoot: repositoryRoot, scannedAt: Date(), worktrees: trees, pairs: pairs)
    }

    private func inspect(
        _ source: GitWorktree, _ target: GitWorktree, git: AgentControlGit
    ) async throws
        -> WorktreeCollisionPair?
    {
        let heads = [source.head, target.head]
        let (base, merge) = try await mergeInfo(git, heads: heads)
        async let sourceChanges = changes(in: source, base: base)
        async let targetChanges = changes(in: target, base: base)
        let (a, b) = try await (sourceChanges, targetChanges)
        let paths = Set(a.keys).intersection(b.keys).union(merge.paths).sorted()
        guard !paths.isEmpty || merge.conflict else { return nil }
        let files = try await collisions(paths, source: a, target: b, merge: merge, git: git)
        return WorktreeCollisionPair(
            sourceWorktree: source, targetWorktree: target, mergeBase: base,
            severity: merge.conflict ? .high : files.map(\.severity).max() ?? .low, collisions: files,
            mergeTreeMessages: merge.messages, hasTreeConflict: merge.conflict)
    }

    private func collisions(
        _ paths: [String], source: [String: Parser.Change], target: [String: Parser.Change],
        merge: Parser.Merge, git: AgentControlGit
    ) async throws -> [FileCollision] {
        var files: [FileCollision] = []
        var budget = 10
        for path in paths {
            let conflict = merge.paths.contains(path)
            let (severity, overlaps) = Parser.classify(
                source[path] ?? .init(), target[path] ?? .init(), conflict: conflict)
            var preview: CollisionPreviewContent?
            if conflict, let tree = merge.tree, budget > 0 {
                budget -= 1
                preview = try await blob(git, tree: tree, path: path)
            }
            files.append(
                FileCollision(
                    path: path, severity: severity, overlappingRanges: overlaps,
                    hasMergeConflict: conflict, previewContent: preview))
        }
        return files
    }

    private func mergeInfo(_ git: AgentControlGit, heads: [String]) async throws -> (String?, Parser.Merge) {
        guard heads.allSatisfy(Self.hasHead) else { return (nil, .init()) }
        let result = try await git.run(["merge-base"] + heads, accepting: [0, 1])
        let base = result.exitCode == 0 ? GitOutput.withoutTerminalLF(result.text) : nil
        return (base, try await mergeTree(git, heads: heads))
    }

    private static func hasHead(_ oid: String) -> Bool {
        GitParsers.isObjectID(oid) && oid.contains { $0 != "0" }
    }

    private func changes(in tree: GitWorktree, base: String?) async throws -> [String: Parser.Change] {
        let git = AgentControlGit(root: URL(fileURLWithPath: tree.path), runner: runner)
        let head = Self.hasHead(tree.head) ? tree.head : nil
        let args = AgentControlGit.diffOptions + ["--raw", "-z", "--patch", "-U0", "--ignore-submodules=none"]
        let result = try await git.run(args + [base ?? head].compactMap { $0 } + ["--"])
        var changes = Parser.changes(result.stdout)
        let status = try await git.run(["status", "--porcelain=v1", "-z", "--no-renames", "--untracked-files=all"])
        for field in GitOutput.nulFields(status.stdout)
        where field.hasPrefix("?? ") || (head == nil && field.hasPrefix("A")) {
            changes[String(field.dropFirst(3))] = .init(isNew: true)
        }
        return changes
    }

    public func conflictPreview(
        repositoryRoot: URL, sourceRef: String, targetRef: String, path: String
    ) async throws -> String? {
        try await conflictPreviewContent(
            repositoryRoot: repositoryRoot, sourceRef: sourceRef,
            targetRef: targetRef, path: path)?.text
    }

    public func conflictPreviewContent(
        repositoryRoot: URL, sourceRef: String, targetRef: String, path: String
    ) async throws -> CollisionPreviewContent? {
        try GitInput.validateComponents(path)
        let git = AgentControlGit(root: repositoryRoot, runner: runner)
        guard let source = try await git.resolve(sourceRef), let target = try await git.resolve(targetRef) else {
            throw GitError.invalidReference
        }
        let merge = try await mergeTree(git, heads: [source, target])
        guard merge.paths.contains(path), let tree = merge.tree else { return nil }
        return try await blob(git, tree: tree, path: path)
    }

    private func mergeTree(_ git: AgentControlGit, heads: [String]) async throws -> Parser.Merge {
        let args = [
            "-c", "merge.conflictStyle=diff3", "merge-tree", "--write-tree", "--name-only",
            "--messages", "--allow-unrelated-histories", "-z",
        ]
        return try Parser.merge(await git.run(args + heads, accepting: [0, 1]))
    }

    private func blob(_ git: AgentControlGit, tree: String, path: String) async throws -> CollisionPreviewContent? {
        let object = tree + ":" + path
        let kind = try await git.run(["cat-file", "-t", object], accepting: [0, 128])
        guard kind.text == "blob\n" else { return nil }
        let limit = 32 * 1_024
        do {
            let result = try await git.run(["show", object], limit: limit)
            let excerpt = AgentControlGit.excerpt(result.stdout, limit: limit)
            return CollisionPreviewContent(text: excerpt.text, isTruncated: excerpt.truncated)
        } catch CommandError.outputLimitExceeded {
            let temporary = try PrivateTemporaryDirectory.make(
                prefix: "GitaPreview", failure: LocalFileError.destinationNotCreated)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let directory = try await git.run(["rev-parse", "--absolute-git-dir"])
            let local = AgentControlGit(root: temporary, runner: runner)
            let file = try await local.run([
                "--git-dir=" + GitOutput.withoutTerminalLF(directory.text), "unpack-file", object,
            ])
            let name = GitOutput.withoutTerminalLF(file.text)
            try GitInput.validateComponents(name)
            let excerpt = try AgentControlGit.prefix(of: temporary.appendingPathComponent(name), limit: limit)
            return CollisionPreviewContent(text: excerpt.text, isTruncated: excerpt.truncated)
        }
    }
}
