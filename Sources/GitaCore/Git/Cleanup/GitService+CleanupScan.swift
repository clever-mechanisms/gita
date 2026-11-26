import Foundation

extension GitService {
    public func scanCleanupCandidates(
        staleThresholdDays: Int = 30, now: Date = Date(), worktreeIdleThresholdDays: Int = 14
    ) async throws -> CleanupScanReport {
        let inventory = try await workflowBranches()
        let base = inventory.defaultReference?.name ?? inventory.currentBranch
        let staleDays = max(0, staleThresholdDays)
        let worktreeDays = max(0, worktreeIdleThresholdDays)
        var report = CleanupScanReport(defaultBranch: base)
        if !inventory.refs.isEmpty {
            let target = inventory.mergeTarget
            async let merged = execute(["for-each-ref", "--merged=" + target, "--format=%(refname)", "refs/heads/"])
            let format = "%(refname)%00%(objectname)%00%(upstream:track)%00%(committerdate:unix)%00"
            let rows = try await execute(["for-each-ref", "--format=" + format, "refs/heads/"])
            let mergedNames = try await Set(GitOutput.lines(merged.text))
            let protected = inventory.protectedNames
            report.branches = GitOutput.lines(rows.text).compactMap { line in
                Self.cleanupCandidate(
                    line, protected: protected, merged: mergedNames, staleThresholdDays: staleDays, now: now)
            }
        }
        for tree in inventory.removableWorktrees {
            try Task.checkCancellation()
            if let candidate = try await inspectCleanupWorktree(tree, now: now, idleThresholdDays: worktreeDays) {
                report.worktrees.append(candidate)
            }
        }
        return report
    }

    private static func cleanupCandidate(
        _ line: String, protected: Set<String>, merged: Set<String>, staleThresholdDays: Int, now: Date
    ) -> CleanupBranchCandidate? {
        let fields = line.components(separatedBy: "\0")
        guard fields.count == 5, let name = fields[0].dropPrefix("refs/heads/"), !protected.contains(name),
            let seconds = TimeInterval(fields[3])
        else { return nil }
        let date = Date(timeIntervalSince1970: seconds)
        let age = max(0, Int(now.timeIntervalSince(date) / 86_400))
        var reasons: [CleanupBranchReason] = []
        if merged.contains(fields[0]) { reasons.append(.merged) }
        if fields[2].contains("[gone]") { reasons.append(.goneUpstream) }
        if age >= staleThresholdDays { reasons.append(.stale(days: age)) }
        guard !reasons.isEmpty else { return nil }
        return CleanupBranchCandidate(name: name, commit: fields[1], ageDays: age, reasons: reasons)
    }

    private func inspectCleanupWorktree(
        _ tree: GitWorktree, now: Date, idleThresholdDays: Int
    ) async throws -> CleanupWorktreeCandidate? {
        if tree.isPrunable || !FileManager.default.fileExists(atPath: tree.path) {
            var missing = tree
            missing.isPrunable = true
            return CleanupWorktreeCandidate(worktree: missing, idleDays: 0, isDirty: false)
        }
        let idleDays = await Task.detached(priority: .utility) { Self.worktreeIdleDays(at: tree.path, now: now) }.value
        guard idleDays >= idleThresholdDays else { return nil }
        let dirty = try await cleanupWorktreeIsDirty(tree.path)
        return CleanupWorktreeCandidate(worktree: tree, idleDays: idleDays, isDirty: dirty)
    }

    func cleanupWorktreeIsDirty(_ path: String) async throws -> Bool {
        let status = try await execute([
            "-C", path, "-c", "core.fsmonitor=false", "--no-optional-locks", "status", "--porcelain=v2",
            "--untracked-files=all", "--ignore-submodules=none", "-z",
        ])
        return !status.stdout.isEmpty
    }

    private static func worktreeIdleDays(at path: String, now: Date) -> Int {
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        var candidates = [directory]
        if let gitDir = linkedGitDirectory(for: directory) {
            candidates += [
                gitDir.appendingPathComponent("index"),
                gitDir.appendingPathComponent("logs/HEAD"),
                gitDir.appendingPathComponent("HEAD"),
            ]
        }
        let newest = candidates.compactMap(modificationDate(of:)).max() ?? now
        return max(0, Int(now.timeIntervalSince(newest) / 86_400))
    }

    private static func linkedGitDirectory(for worktree: URL) -> URL? {
        let dotGit = worktree.appendingPathComponent(".git")
        guard
            let values = try? dotGit.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]),
            values.isSymbolicLink != true
        else { return nil }
        if values.isDirectory == true { return dotGit }
        guard values.isRegularFile == true, let data = try? Data(contentsOf: dotGit), data.count <= 8_192 else {
            return nil
        }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rawPath = text.dropPrefix("gitdir:")?.trimmingCharacters(in: .whitespaces), !rawPath.isEmpty else {
            return nil
        }
        return rawPath.hasPrefix("/")
            ? URL(fileURLWithPath: rawPath, isDirectory: true)
            : worktree.appendingPathComponent(rawPath, isDirectory: true).standardizedFileURL
    }

    private static func modificationDate(of url: URL) -> Date? {
        guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .contentModificationDateKey]),
            values.isSymbolicLink != true
        else { return nil }
        return values.contentModificationDate
    }
}
