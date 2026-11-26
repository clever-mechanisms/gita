import Foundation

public enum CommitBucketPlanner {
    public static func loadPlan(from gitService: GitService) async throws -> CommitBucketPlan {
        let head = try await gitService.headCommit()
        let status = try await gitService.execute([
            "status", "--porcelain=v2", "-z", "--no-renames", "--untracked-files=all",
        ])
        let changes = GitParsers.status(status.stdout).changes
        guard !changes.contains(where: \.isConflict) else { throw GitError.unresolvedConflicts }
        let grouped = Dictionary(grouping: changes, by: \.path)
        var items: [BucketHunkItem] = []
        for path in grouped.keys.sorted() {
            try Task.checkCancellation()
            guard let entries = grouped[path], let first = entries.first else { continue }
            let change = entries.first(where: \.isUntracked) ?? first
            items += try await load(change, head: head, service: gitService)
        }
        let buckets = (1...(items.count <= 1 ? 1 : 2)).map { CommitBucket(title: String(localized: "Commit \($0)")) }
        return .init(items: items, buckets: buckets, baseHeadID: head)
    }

    private static func load(_ change: FileChange, head: String?, service: GitService) async throws -> [BucketHunkItem]
    {
        try GitInput.validatePath(change.path)
        try GitInput.validateComponents(change.path)
        let diff: CommandResult
        let options =
            ["diff", "--full-index", "--no-renames", "--src-prefix=a/", "--dst-prefix=b/"] + GitArguments.safeDiff
        if let head, !change.isUntracked {
            diff = try await service.execute(options + [head, "--", change.path])
        } else {
            if !change.isUntracked && change.worktreeCode == .deleted { return [] }
            diff = try await service.execute(
                options + ["--no-index", "--", "/dev/null", change.path], allowFailure: true)
            guard diff.exitCode == 0 || diff.exitCode == 1 else { throw GitService.failure(diff) }
        }
        guard !diff.stdout.isEmpty else { return [] }
        let patch = diff.text
        let document = UnifiedDiff.parse(patch)
        let lines = Dictionary(grouping: document.lines, by: \.hunkIndex)
        if document.canApplyHunks, Data(patch.utf8) == diff.stdout {
            return document.hunks.map { hunk in
                item(
                    path: change.path, patch: hunk.patch, lines: lines[hunk.index] ?? [], index: hunk.index, kind: .hunk
                )
            }
        }
        let kind: BucketItemKind
        if change.isUntracked {
            kind = .untrackedFile
        } else if patch.contains("\ndeleted file mode ") {
            kind = .wholeFileDeleted
        } else if patch.contains("\nnew file mode ") {
            kind = .wholeFileAdded
        } else {
            kind = .wholeFileModified
        }
        return [item(path: change.path, patch: patch, lines: document.lines, index: nil, kind: kind)]
    }

    private static func item(
        path: String, patch: String, lines: [DiffLine], index: Int?, kind: BucketItemKind
    )
        -> BucketHunkItem
    {
        let header = lines.first(where: { $0.kind == "@" })?.text ?? path
        let summary = lines.first(where: { $0.kind == "+" || $0.kind == "-" })?.text ?? path
        let old = lines.compactMap { Int($0.old) }
        return .init(
            id: "\(path):\(index.map(String.init) ?? "file")", path: path, hunkIndex: index,
            header: header, summary: summary, patch: patch, oldLineStart: old.first, oldLineEnd: old.last,
            kind: kind)
    }

    public static func addBucket(to plan: CommitBucketPlan) -> CommitBucketPlan {
        var plan = plan
        plan.buckets.append(.init(title: String(localized: "Commit \(plan.buckets.count + 1)")))
        return plan
    }

    public static func removeBucket(_ id: UUID, from plan: CommitBucketPlan) -> CommitBucketPlan {
        var plan = plan
        plan.buckets.removeAll { $0.id == id }
        return plan
    }

    public static func updateBucketMessage(
        _ id: UUID, title: String, body: String, in plan: CommitBucketPlan
    )
        -> CommitBucketPlan
    {
        var plan = plan
        guard let index = plan.buckets.firstIndex(where: { $0.id == id }) else { return plan }
        plan.buckets[index].title = title
        plan.buckets[index].body = body
        return plan
    }

    public static func assign(itemID: String, to bucketID: UUID, in plan: CommitBucketPlan) -> CommitBucketPlan {
        guard plan.items.contains(where: { $0.id == itemID }) else { return plan }
        return assign(ids: [itemID], to: bucketID, in: plan)
    }

    public static func assignFile(path: String, to bucketID: UUID, in plan: CommitBucketPlan) -> CommitBucketPlan {
        assign(ids: plan.items.filter { $0.path == path }.map(\.id), to: bucketID, in: plan)
    }

    private static func assign(ids: [String], to bucketID: UUID, in plan: CommitBucketPlan) -> CommitBucketPlan {
        guard let index = plan.buckets.firstIndex(where: { $0.id == bucketID }) else { return plan }
        var plan = plan
        let moved = Set(ids)
        for index in plan.buckets.indices { plan.buckets[index].itemIDs.removeAll(where: moved.contains) }
        plan.buckets[index].itemIDs.append(contentsOf: ids)
        return plan
    }

    public static func unassign(itemID: String, in plan: CommitBucketPlan) -> CommitBucketPlan {
        var plan = plan
        for index in plan.buckets.indices { plan.buckets[index].itemIDs.removeAll { $0 == itemID } }
        return plan
    }

    public static func moveBucket(from: Int, to: Int, in plan: CommitBucketPlan) -> CommitBucketPlan {
        var plan = plan
        guard plan.buckets.indices.contains(from), plan.buckets.indices.contains(to) else { return plan }
        plan.buckets.insert(plan.buckets.remove(at: from), at: to)
        return plan
    }

    public static func unassignedItems(in plan: CommitBucketPlan) -> [BucketHunkItem] {
        let assigned = Set(plan.buckets.flatMap(\.itemIDs))
        return plan.items.filter { !assigned.contains($0.id) }
    }

    public static func items(in bucket: CommitBucket, of plan: CommitBucketPlan) -> [BucketHunkItem] {
        let assigned = Set(bucket.itemIDs)
        return plan.items.filter { assigned.contains($0.id) }
    }

    public static func synthesizedDiff(for bucket: CommitBucket, in plan: CommitBucketPlan) -> String {
        synthesizedDiff(items: items(in: bucket, of: plan))
    }

    static func synthesizedDiff(items: [BucketHunkItem]) -> String {
        let groups = Dictionary(grouping: items, by: \.path)
        var patch = ""
        for path in groups.keys.sorted() {
            let ordered = (groups[path] ?? []).sorted { ($0.hunkIndex ?? 0) < ($1.hunkIndex ?? 0) }
            for (index, item) in ordered.enumerated() {
                if index > 0, let boundary = item.patch.range(of: "\n@@ ") {
                    patch += item.patch[item.patch.index(after: boundary.lowerBound)...]
                } else {
                    patch += item.patch
                }
            }
        }
        return patch
    }

    public static func validate(_ plan: CommitBucketPlan) -> [BucketValidationIssue] {
        let active = plan.buckets.filter { !$0.itemIDs.isEmpty }
        if active.isEmpty { return plan.buckets.map { .emptyBucket(bucketID: $0.id) } }
        var issues: [BucketValidationIssue] = []
        var owners: [String: [UUID]] = [:]
        var covered: [String: Int] = [:]
        for bucket in active {
            if bucket.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.emptyTitle(bucketID: bucket.id))
            }
            for id in bucket.itemIDs { owners[id, default: []].append(bucket.id) }
            for item in items(in: bucket, of: plan) {
                guard let start = item.oldLineStart, let end = item.oldLineEnd else { continue }
                if let previous = covered[item.path], start <= previous {
                    let detail = String(localized: "Place earlier hunks first to preserve their context.")
                    issues.append(.hunkOrderOverlap(path: item.path, detail: detail))
                }
                covered[item.path] = max(covered[item.path] ?? end, end)
            }
        }
        for id in owners.keys.sorted() {
            if let ids = owners[id], ids.count > 1 { issues.append(.duplicateAssignment(itemID: id, bucketIDs: ids)) }
        }
        return issues
    }
}
