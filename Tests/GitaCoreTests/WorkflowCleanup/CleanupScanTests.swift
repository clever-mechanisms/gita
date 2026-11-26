import Foundation
import Testing

@testable import GitaCore

@Suite struct WorkflowCleanupScanTests {
    @Test func classifiesBranchesAndHonorsRemoteDefaultAndCheckedOutBranches() async throws {
        let repo = try await ReferenceFixture()
        defer { repo.remove() }
        let remote = repo.container.appendingPathComponent("remote.git")
        try await repo.git(["init", "--bare", remote.path])
        try await repo.git(["remote", "add", "origin", remote.path])
        try await repo.git(["branch", "trunk"])
        try await repo.git(["push", "origin", "trunk"])
        try await repo.git(["remote", "set-head", "origin", "trunk"])
        try await repo.git(["branch", "merged"])
        try await repo.git(["branch", "gone"])
        try await repo.git(["push", "--set-upstream", "origin", "gone"])
        try await repo.git(["push", "origin", "--delete", "gone"])
        let old = try await oldCommit(repo)
        try await repo.git(["branch", "old", old])
        let linked = repo.container.appendingPathComponent("linked")
        try await repo.git(["worktree", "add", "-b", "busy", linked.path])
        let report = try await repo.service.scanCleanupCandidates()
        #expect(report.defaultBranch == "trunk")
        #expect(Set(report.branches.map(\.name)) == ["merged", "gone", "old"])
        #expect(report.branches.first { $0.name == "gone" }?.reasons.contains(.goneUpstream) == true)
        let merged = try #require(report.branches.first { $0.name == "merged" })
        #expect(merged.isMerged && !merged.requiresForceToDelete)
        let stale = try #require(report.branches.first { $0.name == "old" })
        #expect(stale.ageDays > 100 && stale.reasons == [.stale(days: stale.ageDays)])
        #expect(stale.requiresForceToDelete)
        #expect(report.worktrees.isEmpty)
    }

    private func oldCommit(_ repo: ReferenceFixture) async throws -> String {
        let tree = try await repo.oid("HEAD^{tree}")
        let object = repo.container.appendingPathComponent("old.commit")
        let identity = "Old <old@example.invalid> 1000000000 +0000"
        try Data("tree \(tree)\nauthor \(identity)\ncommitter \(identity)\n\nOld change\n".utf8).write(to: object)
        return try await repo.git(["hash-object", "-w", "-t", "commit", object.path]).text.trimmingCharacters(
            in: .newlines)
    }

    @Test func protectsWorktreesAndContinuesBatchAfterFailures() async throws {
        let repo = try await ReferenceFixture()
        defer { repo.remove() }
        var paths: [String: String] = [:]
        for name in ["locked", "dirty", "clean", "missing"] {
            let path = repo.container.appendingPathComponent(name).path
            try await repo.git(["worktree", "add", "-b", name, path])
            paths[name] = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        }
        let locked = try #require(paths["locked"])
        let dirty = try #require(paths["dirty"])
        let clean = try #require(paths["clean"])
        let missing = try #require(paths["missing"])
        try await repo.git(["worktree", "lock", locked])
        try Data("unsaved".utf8).write(to: URL(fileURLWithPath: dirty).appendingPathComponent("unsaved"))
        try FileManager.default.removeItem(atPath: missing)
        try await repo.git(["branch", "merged"])
        let unmergedOID = try await oldCommit(repo)
        try await repo.git(["branch", "unmerged", unmergedOID])
        let mainOID = try await repo.oid("main")
        let cleanOID = try await repo.oid("clean")
        let mergedOID = try await repo.oid("merged")
        let report = try await repo.service.scanCleanupCandidates(worktreeIdleThresholdDays: 0)
        #expect(Set(report.worktrees.map(\.path)) == [dirty, clean, missing])
        #expect(report.worktrees.first { $0.path == dirty }?.isDirty == true)
        #expect(report.worktrees.first { $0.path == missing }?.isPrunable == true)
        let result = try await repo.service.executeCleanup(
            .init(
                branches: ["unmerged": unmergedOID, "main": mainOID, "clean": cleanOID, "merged": mergedOID],
                worktreePaths: [locked, repo.root.path, dirty, clean, missing]))
        #expect(result.deletedBranches == ["merged"] && Set(result.removedWorktrees) == [clean, missing])
        #expect(Set(result.failures.map(\.target)) == ["unmerged", "main", "clean", locked, repo.root.path, dirty])
        #expect(try await repo.exists("refs/heads/unmerged"))
        #expect(try await !repo.git(["worktree", "list", "--porcelain"]).text.contains(missing))
        let forced = try await repo.service.executeCleanup(
            .init(branches: ["main": mainOID, "unmerged": unmergedOID], allowUnmergedBranchDelete: true))
        #expect(forced.deletedBranches == ["unmerged"] && forced.failures.map(\.target) == ["main"])
    }

    @Test func deletesMergedBranchFromNonDefaultCheckoutAndRejectsStaleCommit() async throws {
        let repo = try await ReferenceFixture()
        defer { repo.remove() }
        try await repo.git(["branch", "merged-gone"])
        try await repo.git(["branch", "moved"])
        let movedOriginal = try await repo.oid("moved")
        try await repo.git(["switch", "-c", "active-feature"])
        try repo.write("feature.txt", "wip\n")
        try await repo.commit("Feature work")
        let report = try await repo.service.scanCleanupCandidates()
        let mergedCandidate = try #require(report.branches.first { $0.name == "merged-gone" })
        try await repo.git(["update-ref", "refs/heads/moved", try await repo.oid("HEAD")])
        let result = try await repo.service.executeCleanup(
            .init(branches: ["merged-gone": mergedCandidate.commit, "moved": movedOriginal]))
        #expect(result.deletedBranches == ["merged-gone"])
        #expect(result.failures.map(\.target) == ["moved"])
        #expect(try await !repo.exists("refs/heads/merged-gone"))
        #expect(try await repo.exists("refs/heads/moved"))
    }

    @Test func handlesOrphanWorktreeAndMeasuresIdleFromActivityNotOldCommit() async throws {
        let repo = try await ReferenceFixture()
        defer { repo.remove() }
        let old = try await oldCommit(repo)
        try await repo.git(["branch", "ancient", old])
        let freshWorktree = repo.container.appendingPathComponent("fresh-old-branch")
        try await repo.git(["worktree", "add", freshWorktree.path, "ancient"])
        let orphanWorktree = repo.container.appendingPathComponent("orphan-tree")
        try await repo.git(["worktree", "add", "--orphan", "-b", "orphan-branch", orphanWorktree.path])
        let defaultThreshold = try await repo.service.scanCleanupCandidates()
        #expect(defaultThreshold.worktrees.isEmpty)
        let zeroThreshold = try await repo.service.scanCleanupCandidates(worktreeIdleThresholdDays: 0)
        #expect(zeroThreshold.worktrees.count == 2)
        #expect(zeroThreshold.worktrees.allSatisfy { $0.idleDays == 0 })
    }

    @Test func selectingOneMissingWorktreePreservesTheOthers() async throws {
        let repo = try await ReferenceFixture()
        defer { repo.remove() }
        for name in ["first", "second"] {
            let path = repo.container.appendingPathComponent(name)
            try await repo.git(["worktree", "add", "-b", name, path.path])
            try FileManager.default.removeItem(at: path)
        }
        let scan = try await repo.service.scanCleanupCandidates()
        let selected = try #require(scan.worktrees.first { $0.branch == "second" })
        let result = try await repo.service.executeCleanup(.init(worktreePaths: [selected.path]))
        #expect(result.removedWorktrees == [selected.path] && result.failures.isEmpty)
        #expect(try await repo.service.scanCleanupCandidates().worktrees.compactMap(\.branch) == ["first"])
    }

    @Test func rechecksBranchOccupancyAfterScan() async throws {
        let repo = try await ReferenceFixture()
        defer { repo.remove() }
        try await repo.git(["branch", "reviewed"])
        let report = try await repo.service.scanCleanupCandidates()
        let candidate = try #require(report.branches.first)
        #expect(candidate.name == "reviewed")
        let linked = repo.container.appendingPathComponent("new checkout")
        try await repo.git(["worktree", "add", linked.path, "reviewed"])
        let result = try await repo.service.executeCleanup(
            .init(branches: ["reviewed": candidate.commit], allowUnmergedBranchDelete: true))
        #expect(result.failures.map(\.target) == ["reviewed"])
        let fromLinked = try await GitService(root: linked).scanCleanupCandidates(worktreeIdleThresholdDays: 0)
        #expect(fromLinked.worktrees.isEmpty)
    }
}
