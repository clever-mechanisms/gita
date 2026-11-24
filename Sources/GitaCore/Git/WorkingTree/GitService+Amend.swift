import Foundation

/// What an Amend Last Commit would rewrite: HEAD's message, and whether that commit is already public.
extension GitService {
    public struct AmendCommit: Sendable, Equatable {
        public var id: String
        public var message: String
        /// The tree to compare the index against while amending: HEAD's first parent, or the empty tree for a root
        /// commit.
        public var baseTree: String
        /// HEAD is contained in the branch's upstream, so publishing the rewrite needs a force push.
        public var isPublished: Bool
        public var isDetached: Bool
        /// Abbreviated upstream name (e.g. `origin/main`) when `isPublished` is true.
        public var upstream: String?

        public init(
            id: String, message: String, baseTree: String = "", isPublished: Bool, isDetached: Bool,
            upstream: String? = nil
        ) {
            self.id = id
            self.message = message
            self.baseTree = baseTree
            self.isPublished = isPublished
            self.isDetached = isDetached
            self.upstream = upstream
        }
    }

    /// Nil in a repository that has no commit yet.
    public func amendCommit() async throws -> AmendCommit? {
        guard let id = try await headCommit() else { return nil }
        async let details = commitDetails(ref: id)
        async let published = publishedUpstream()
        async let detached = headIsDetached()
        let loaded = try await details
        let baseTree = try await amendBaseTree(for: loaded.commit)
        let upstream = try await published
        return try await AmendCommit(
            id: id, message: loaded.message, baseTree: baseTree, isPublished: upstream != nil,
            isDetached: detached, upstream: upstream)
    }

    /// Staged changes relative to `base` (HEAD's first parent or the empty tree when amending).
    public func stagedChanges(against base: String) async throws -> [FileChange] {
        try GitInput.validateReference(base)
        let data = try await execute(
            ["diff", "--cached"] + GitArguments.safeDiff + ["--name-status", "-z", "--find-renames", base, "--"]
        ).stdout
        return GitParsers.changedFiles(data)
    }

    /// Restores the index entries for `paths` back to `HEAD` without touching the working tree.
    public func restoreStagedToHead(paths: [String]) async throws {
        try GitInput.validatePaths(paths)
        guard !paths.isEmpty else { return }
        try await mutate { service in
            guard try await service.headCommit() != nil else { return }
            async let headPaths = service.execute(["ls-tree", "--name-only", "-z", "HEAD", "--"] + paths)
            async let indexPaths = service.execute(["ls-files", "-z", "--"] + paths)
            let valid = Set(
                try await GitOutput.nulFields(headPaths.stdout) + GitOutput.nulFields(indexPaths.stdout)
            ).filter { !$0.isEmpty }.sorted()
            guard !valid.isEmpty else { return }
            _ = try await service.execute(["restore", "--staged", "--"] + valid, mutation: true)
        }
    }

    private func amendBaseTree(for commit: GitCommit) async throws -> String {
        if let parent = commit.parents.first {
            let check = try await execute(["rev-parse", "--verify", "--quiet", parent + "^{tree}"], allowFailure: true)
            if check.exitCode == 0 { return parent }
            guard check.exitCode == 1 else { throw Self.failure(check) }
        }
        let empty = try await execute(["hash-object", "-t", "tree", "/dev/null"], outputLimit: 256)
        return GitOutput.withoutTerminalLF(empty.text)
    }

    /// The upstream short name (e.g. `origin/main`) when `@{upstream}` exists and already contains HEAD.
    private func publishedUpstream() async throws -> String? {
        let upstream = try await execute(
            ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "--quiet", "@{upstream}"], allowFailure: true)
        guard upstream.exitCode == 0 else {
            guard upstream.exitCode == 1 || upstream.exitCode == 128 else { throw Self.failure(upstream) }
            return nil
        }
        guard try await isAncestor("HEAD", of: "@{upstream}") else { return nil }
        let name = GitOutput.withoutTerminalLF(upstream.text).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private func headIsDetached() async throws -> Bool {
        let result = try await execute(["symbolic-ref", "--quiet", "HEAD"], allowFailure: true)
        if result.exitCode == 1 { return true }
        guard result.exitCode == 0 else { throw Self.failure(result) }
        return false
    }
}
