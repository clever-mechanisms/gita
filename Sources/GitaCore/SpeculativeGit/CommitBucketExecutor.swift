import Foundation

public actor CommitBucketExecutor {
    private let gitService: GitService

    public init(gitService: GitService) { self.gitService = gitService }

    public func execute(
        plan: CommitBucketPlan, onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws
        -> CommitBucketExecutionResult
    {
        let buckets = plan.buckets.filter { !$0.itemIDs.isEmpty }
        guard !buckets.isEmpty else { throw GitError.emptyMessage }
        if let issue = CommitBucketPlanner.validate(plan).first { throw GitError.commandFailed(issue.message) }
        return try await gitService.mutate { service in
            try await service.requireNoOperation()
            let ref = try await service.bucketBranch()
            let head = try await service.headCommit()
            guard head == plan.baseHeadID else { throw GitError.staleReference }
            let fresh = try await CommitBucketPlanner.loadPlan(from: service)
            let current = Set(fresh.items)
            let directory = try PrivateTemporaryDirectory.make(
                prefix: "GitaBuckets", failure: LocalFileError.temporaryPatchNotCreated)
            defer { try? FileManager.default.removeItem(at: directory) }
            let transaction = BucketIndex(service: service, directory: directory)
            try await transaction.seed(head)
            var parent = head
            var commits: [CreatedBucketCommit] = []
            for (index, bucket) in buckets.enumerated() {
                try Task.checkCancellation()
                let items = CommitBucketPlanner.items(in: bucket, of: plan)
                guard items.count == bucket.itemIDs.count, items.allSatisfy(current.contains) else {
                    throw GitError.staleDiff
                }
                onProgress?(index + 1, buckets.count)
                let id = try await transaction.commit(bucket, items: items, parent: parent)
                commits.append(.init(bucketID: bucket.id, commitID: id, title: bucket.title))
                parent = id
            }
            guard let final = commits.last?.commitID, try await service.bucketBranch() == ref else {
                throw GitError.staleReference
            }
            try Task.checkCancellation()
            // Finish publication (including recovery) even if the window closes after the compare-and-swap.
            try await Task { try await service.publishBuckets(final, previous: head, branch: ref) }.value
            return .init(createdCommits: commits, previousHeadID: head, newHeadID: final, branchRef: ref)
        }
    }
}

private struct BucketIndex {
    let service: GitService
    let directory: URL

    func seed(_ head: String?) async throws {
        // CommandRunning's argv-only adapter cannot forward environment overrides.
        // Verify the alternate index before issuing even the first index write.
        let selected = try await run(["rev-parse", "--git-path", "index"])
        let path = GitOutput.withoutTerminalLF(selected.text)
        let expected = directory.appendingPathComponent("index")
        guard path == expected.path else {
            throw GitError.commandFailed(String(localized: "Git could not select the temporary index."))
        }
        if let head { _ = try await run(["read-tree", head]) }
    }

    func run(_ arguments: [String]) async throws -> CommandResult {
        var request = try await service.gitRequest(
            GitArguments.noHooks + ["-c", "core.fsmonitor=false"] + arguments,
            outputLimit: CommandRequest.defaultOutputLimit)
        request.environment.added["GIT_INDEX_FILE"] = directory.appendingPathComponent("index").path
        let result = try await service.runner.run(request)
        guard result.exitCode == 0 else { throw GitService.failure(result) }
        return result
    }

    func commit(_ bucket: CommitBucket, items: [BucketHunkItem], parent: String?) async throws -> String {
        let hunks = items.filter { $0.kind == .hunk }
        if !hunks.isEmpty {
            let file = directory.appendingPathComponent("changes.patch")
            try Data(CommitBucketPlanner.synthesizedDiff(items: hunks).utf8).write(to: file)
            _ = try await run(["apply", "--cached", "--whitespace=nowarn", "--", file.path])
        }
        for item in items where item.kind != .hunk { try await stage(item) }
        let tree = try GitService.speculativeObjectID(await run(["write-tree"]))
        let message = directory.appendingPathComponent("message")
        try Data((bucket.commitMessage + "\n").utf8).write(to: message)
        return try await service.bucketObjectID(
            ["commit-tree", tree] + (parent.map { ["-p", $0] } ?? []) + ["-F", message.path])
    }

    private func stage(_ item: BucketHunkItem) async throws {
        try GitInput.validateComponents(item.path)
        if item.kind == .wholeFileDeleted {
            _ = try await run(["update-index", "--force-remove", "--", item.path])
            return
        }
        let root = try await service.repositoryRoot()
        let file = root.appendingPathComponent(item.path)
        let parent = file.deletingLastPathComponent()
        guard parent.resolvingSymlinksInPath().standardizedFileURL.path == parent.standardizedFileURL.path else {
            throw GitError.invalidPath
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let blob: String
        let mode: String
        switch attributes[.type] as? FileAttributeType {
        case .typeRegular:
            blob = try await service.bucketObjectID(["hash-object", "-w", "--", file.path])
            let permissions = attributes[.posixPermissions] as? Int
            mode = (permissions ?? 0) & 0o100 == 0 ? "100644" : "100755"
        case .typeSymbolicLink:
            let link = try FileManager.default.destinationOfSymbolicLink(atPath: file.path)
            let target = directory.appendingPathComponent("link")
            try Data(link.utf8).write(to: target)
            blob = try await service.bucketObjectID(["hash-object", "-w", "--no-filters", "--", target.path])
            mode = "120000"
        default: throw GitError.invalidPath
        }
        if let reviewed = GitService.binaryObjectIDs(in: item.patch).new, reviewed != blob { throw GitError.staleDiff }
        _ = try await run(["update-index", "--add", "--cacheinfo", "\(mode),\(blob),\(item.path)"])
    }
}

extension GitService {
    fileprivate func bucketBranch() async throws -> String? {
        let result = try await execute(["symbolic-ref", "-q", "HEAD"], allowFailure: true)
        if result.exitCode == 1 { return nil }
        guard result.exitCode == 0 else { throw Self.failure(result) }
        return GitOutput.withoutTerminalLF(result.text)
    }

    fileprivate func publishBuckets(_ final: String, previous: String?, branch: String?) async throws {
        let ref = branch ?? "HEAD"
        let args =
            GitArguments.noHooks + ["update-ref"] + (branch == nil ? ["--no-deref"] : [])
            + ["-m", "Gita commit buckets"]
        let old = previous ?? String(repeating: "0", count: final.count)
        _ = try await execute(args + [ref, final, old], mutation: true)
        do {
            guard try await bucketBranch() == branch, try await headCommit() == final else {
                throw GitError.staleReference
            }
            _ = try await execute(GitArguments.noHooks + ["read-tree", "HEAD"], mutation: true)
        } catch {
            let rollback = previous.map { [ref, $0, final] } ?? ["-d", ref, final]
            _ = try await execute(args + rollback, mutation: true)
            throw error
        }
    }
}
