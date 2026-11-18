import Darwin
import Foundation
import Testing

@testable import GitaCore

@Suite(.serialized)
struct GitReferenceTests {
    @Test func renameCurrentAndOtherBranchesPreservesTrackingReflogAndDirtyFiles() async throws {
        let fixture = try await ReferenceFixture()
        defer { fixture.remove() }
        try await fixture.git(["branch", "base"])
        try await fixture.git(["branch", "--set-upstream-to=base", "main"])
        try fixture.write("file.txt", "staged\n")
        try await fixture.git(["add", "file.txt"])
        try fixture.write("file.txt", "working\n")
        try fixture.write("untracked.txt", "preserve\n")
        let index = try Data(contentsOf: fixture.root.appendingPathComponent(".git/index"))
        let details = try await fixture.details("main")
        #expect(details.worktreePaths == [fixture.root.resolvingSymlinksInPath().path])
        #expect(details.upstream?.fullName == "refs/heads/base")
        try await fixture.service.renameBranch(details, to: "renamed/topic")
        #expect(try await fixture.git(["symbolic-ref", "HEAD"]).text == "refs/heads/renamed/topic\n")
        #expect(try await fixture.git(["config", "--get", "branch.renamed/topic.merge"]).text == "refs/heads/base\n")
        #expect(try await fixture.git(["reflog", "show", "--format=%gs", "renamed/topic"]).text.contains("renamed"))
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent(".git/index")) == index)
        #expect(try String(contentsOf: fixture.root.appendingPathComponent("file.txt"), encoding: .utf8) == "working\n")
        #expect(
            try String(contentsOf: fixture.root.appendingPathComponent("untracked.txt"), encoding: .utf8)
                == "preserve\n")
        try await fixture.service.renameBranch(try await fixture.details("base"), to: "release")
        #expect(try await fixture.exists("refs/heads/release"))
        #expect(try await !fixture.exists("refs/heads/base"))
    }

    @Test func literalNamesCollisionsMissingAndSymbolicRefsFailWithoutRetargeting() async throws {
        let fixture = try await ReferenceFixture()
        defer { fixture.remove() }
        try await fixture.git(["branch", "other"])
        let details = try await fixture.details("other")
        for name in ["main", "main/nested", "--force", "@{-1}", "refs/heads/wrong", "HEAD", "bad\nname"] {
            await #expect(throws: GitError.self) { try await fixture.service.renameBranch(details, to: name) }
        }
        for name in ["main", "refs/heads/missing", "refs/heads/other^{commit}", "refs/heads/../main"] {
            await #expect(throws: GitError.self) { _ = try await fixture.service.referenceDetails(fullName: name) }
        }
        try await fixture.git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/heads/main"])
        await #expect(throws: GitError.self) { _ = try await fixture.details("origin/HEAD", kind: .remote) }
        #expect(try await fixture.exists("refs/heads/other"))
        #expect(try await fixture.git(["symbolic-ref", "HEAD"]).text == "refs/heads/main\n")
        try await fixture.service.renameBranch(details, to: "topic/日本語")
        #expect(try await fixture.exists("refs/heads/topic/日本語"))
    }

    @Test func checkedOutLinkedBranchesCannotBeRenamedOrDeleted() async throws {
        let fixture = try await ReferenceFixture()
        defer { fixture.remove() }
        let linked = fixture.container.appendingPathComponent("linked\nworktree")
        try await fixture.git(["worktree", "add", "-b", "linked", linked.path])
        let details = try await fixture.details("linked")
        #expect(details.worktreePaths == [linked.resolvingSymlinksInPath().path])
        await expectReferenceError(.referenceInUse) { try await fixture.service.renameBranch(details, to: "renamed") }
        await expectReferenceError(.referenceInUse) { try await fixture.service.deleteMergedBranch(details) }
        let linkedService = GitService(root: linked)
        let own = try await linkedService.referenceDetails(fullName: "refs/heads/linked")
        try await linkedService.renameBranch(own, to: "own-renamed")
        #expect(try await fixture.git(["symbolic-ref", "HEAD"], at: linked).text == "refs/heads/own-renamed\n")
        await expectReferenceError(.referenceInUse) {
            try await fixture.service.deleteMergedBranch(try await fixture.details("main"))
        }
    }

    @Test(
        .enabled("Requires Git relative-worktree support") { try await supportsReferenceGitFeature(.relativeWorktrees) }
    )
    func relativeLinkedWorktreePointersKeepCanonicalOccupancy() async throws {
        let fixture = try await ReferenceFixture()
        defer { fixture.remove() }
        let linked = fixture.container.appendingPathComponent("relative linked\nworktree")
        try await fixture.git(["worktree", "add", "--relative-paths", "-b", "linked", linked.path])
        let directoryResult = try await fixture.git(["rev-parse", "--absolute-git-dir"], at: linked)
        let directory = String(directoryResult.text.dropLast())
        let pointer = try String(
            contentsOf: URL(fileURLWithPath: directory).appendingPathComponent("gitdir"), encoding: .utf8)
        #expect(!pointer.hasPrefix("/") && pointer.contains("../"))
        let main = try await fixture.details("main")
        #expect(main.reference.isCurrent)
        #expect(main.worktreePaths == [fixture.root.resolvingSymlinksInPath().path])
        let occupied = try await fixture.details("linked")
        #expect(occupied.worktreePaths == [linked.resolvingSymlinksInPath().path])
        await expectReferenceError(.referenceInUse) { try await fixture.service.renameBranch(occupied, to: "blocked") }
        await expectReferenceError(.referenceInUse) { try await fixture.service.deleteMergedBranch(occupied) }
        let linkedReview = try await GitService(root: linked).referenceDetails(fullName: "refs/heads/linked")
        #expect(linkedReview.reference.isCurrent && linkedReview.worktreePaths == occupied.worktreePaths)
    }

    @Test func detachedRebaseAndUpdateRefsReserveBranchesInOtherWorktrees() async throws {
        let fixture = try await ReferenceFixture()
        defer { fixture.remove() }
        let linked = fixture.container.appendingPathComponent("rebasing")
        try await fixture.git(["worktree", "add", "-b", "topic", linked.path])
        try Data("topic\n".utf8).write(to: linked.appendingPathComponent("file.txt"))
        try await fixture.git(["commit", "-am", "Topic"], at: linked)
        try await fixture.git(["branch", "also-rewritten", "topic"])
        try fixture.write("file.txt", "main\n")
        try await fixture.commit("Main")
        let result = try await fixture.git(["rebase", "--update-refs", "main"], at: linked, allowFailure: true)
        #expect(result.exitCode != 0)
        #expect(
            try await fixture.git(["symbolic-ref", "--quiet", "HEAD"], at: linked, allowFailure: true).exitCode == 1)
        for name in ["topic", "also-rewritten"] {
            let details = try await fixture.details(name)
            #expect(details.worktreePaths == [linked.resolvingSymlinksInPath().path])
            await expectReferenceError(.referenceInUse) {
                try await fixture.service.renameBranch(details, to: name + "-renamed")
            }
            await expectReferenceError(.referenceInUse) { try await fixture.service.deleteMergedBranch(details) }
        }
    }

    @Test func bisectReservationAndCurrentBisectBlockReferenceWrites() async throws {
        let fixture = try await ReferenceFixture()
        defer { fixture.remove() }
        let first = try await fixture.oid("HEAD")
        for index in 1...3 {
            try fixture.write("file.txt", "\(index)\n")
            try await fixture.commit("Commit \(index)")
        }
        let last = try await fixture.oid("HEAD")
        let linked = fixture.container.appendingPathComponent("bisecting")
        try await fixture.git(["worktree", "add", "-b", "bisected", linked.path])
        try await fixture.git(["bisect", "start", last, first], at: linked)
        let details = try await fixture.details("bisected")
        #expect(details.worktreePaths == [linked.resolvingSymlinksInPath().path])
        await expectReferenceError(.referenceInUse) { try await fixture.service.renameBranch(details, to: "renamed") }
        try await fixture.git(["bisect", "start"])
        await expectReferenceError(.operationActive) {
            try await fixture.service.createTag(name: "blocked", commitID: last, annotation: nil)
        }
        #expect(try await !fixture.exists("refs/tags/blocked"))
    }

    @Test func mergedDeletionUsesReviewedUpstreamAndRefusesMissingOrUnmergedBasis() async throws {
        let fixture = try await ReferenceFixture()
        defer { fixture.remove() }
        try await fixture.git(["switch", "-c", "topic"])
        try fixture.write("new.txt", "topic\n")
        let topic = try await fixture.commit("Topic")
        try await fixture.git(["branch", "destination"])
        try await fixture.git(["branch", "--set-upstream-to=destination", "topic"])
        try await fixture.git(["switch", "main"])
        let reviewed = try await fixture.details("topic")
        #expect(reviewed.deleteMergeTarget == "refs/heads/destination")
        #expect(reviewed.deleteMergeCommitID == topic)
        #expect(reviewed.mergeStatus == .merged)
        try await fixture.service.deleteMergedBranch(reviewed)
        #expect(try await !fixture.exists("refs/heads/topic"))
        #expect(try await fixture.git(["config", "--get", "branch.topic.merge"], allowFailure: true).exitCode == 1)
        let unmerged = try await fixture.details("destination")
        #expect(unmerged.deleteMergeTarget == "HEAD" && unmerged.mergeStatus == .notMerged)
        await expectReferenceError(.branchNotMerged) { try await fixture.service.deleteMergedBranch(unmerged) }
        try await fixture.git(["branch", "--set-upstream-to=main", "destination"])
        #expect(try await fixture.details("destination").mergeStatus == .notMerged)
        try await fixture.git(["branch", "safe"])
        try await fixture.git(["config", "branch.safe.remote", "."])
        try await fixture.git(["config", "branch.safe.merge", "refs/heads/gone"])
        let missing = try await fixture.details("safe")
        #expect(missing.upstream?.isMissing == true)
        #expect(missing.upstream?.mergeRef == "refs/heads/gone")
        #expect(missing.mergeStatus == .unknown)
        await #expect(throws: ReferenceError.upstreamMissing) { try await fixture.service.deleteMergedBranch(missing) }
        try await fixture.git(["branch", "--unset-upstream", "safe"])
        try await fixture.service.deleteMergedBranch(try await fixture.details("safe"))
    }

    @Test func localRemoteAndCustomMappedUpstreamCanBeSetAndUnset() async throws {
        let fixture = try await ReferenceFixture()
        defer { fixture.remove() }
        try await fixture.git(["branch", "topic"])
        try await fixture.service.setUpstream(try await fixture.details("topic"), to: try await fixture.details("main"))
        #expect(try await fixture.details("topic").upstream?.remoteName == ".")
        try await fixture.service.setUpstream(try await fixture.details("topic"), to: nil)
        #expect(try await fixture.details("topic").upstream == nil)
        let oid = try await fixture.oid("HEAD")
        try await fixture.git([
            "config", "remote.backup.url", fixture.container.appendingPathComponent("unused.git").path,
        ])
        try await fixture.git(["config", "remote.backup.fetch", "+refs/heads/*:refs/remotes/custom/*"])
        try await fixture.git(["update-ref", "refs/remotes/custom/trunk", oid])
        try await fixture.service.setUpstream(
            try await fixture.details("topic"), to: try await fixture.details("custom/trunk", kind: .remote))
        let configured = try await fixture.details("topic")
        #expect(configured.upstream?.remoteName == "backup")
        #expect(configured.upstream?.mergeRef == "refs/heads/trunk")
        #expect(configured.upstream?.fullName == "refs/remotes/custom/trunk")
        #expect(configured.upstream?.objectID == oid)
        await expectReferenceError(.invalidReference) {
            try await fixture.service.setUpstream(configured, to: configured)
        }
        try await fixture.git(["update-ref", "refs/remotes/orphan/main", oid])
        await #expect(throws: ReferenceError.noFetchMapping) {
            try await fixture.service.setUpstream(
                configured, to: try await fixture.details("orphan/main", kind: .remote))
        }
    }

    @Test func settingUpstreamPreservesExplicitAndAbsentRebasePreferences() async throws {
        let fixture = try await ReferenceFixture()
        defer { fixture.remove() }
        try await fixture.git(["config", "branch.autoSetupRebase", "always"])
        let target = try await fixture.details("main")
        for (index, preference) in ["false", "merges", nil].enumerated() {
            let branch = "topic-\(index)"
            let key = "branch.topic-\(index).rebase"
            try await fixture.git(["branch", branch])
            if let preference { try await fixture.git(["config", key, preference]) }
            let before = try await fixture.git(["config", "--get", key], allowFailure: true)
            #expect(before.exitCode == (preference == nil ? 1 : 0))
            try await fixture.service.setUpstream(try await fixture.details(branch), to: target)
            let after = try await fixture.git(["config", "--get", key], allowFailure: true)
            #expect(after.exitCode == before.exitCode && after.stdout == before.stdout)
            #expect(try await fixture.details(branch).upstream?.fullName == target.reference.fullName)
            try await fixture.service.setUpstream(try await fixture.details(branch), to: nil)
            let unset = try await fixture.git(["config", "--get", key], allowFailure: true)
            #expect(unset.exitCode == before.exitCode && unset.stdout == before.stdout)
        }
        #expect(try await fixture.git(["config", "--get", "branch.autoSetupRebase"]).text == "always\n")
    }

    @Test func changedFetchMappingAndUpstreamIdentityRequireReload() async throws {
        let fixture = try await ReferenceFixture()
        defer { fixture.remove() }
        try await fixture.git(["branch", "topic"])
        try await fixture.git(["switch", "-c", "alternate"])
        try fixture.write("file.txt", "changed\n")
        let changed = try await fixture.commit("Changed")
        try await fixture.git(["switch", "main"])
        try await fixture.git([
            "config", "remote.origin.url", fixture.container.appendingPathComponent("unused.git").path,
        ])
        try await fixture.git(["config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*"])
        try await fixture.git(["update-ref", "refs/remotes/origin/main", try await fixture.oid("HEAD")])
        let source = try await fixture.details("topic")
        let target = try await fixture.details("origin/main", kind: .remote)
        try await fixture.git(["config", "--add", "remote.origin.fetch", "^refs/heads/excluded"])
        await expectReferenceError(.staleReference) { try await fixture.service.setUpstream(source, to: target) }
        let freshTarget = try await fixture.details("origin/main", kind: .remote)
        try await fixture.git(["update-ref", "refs/remotes/origin/main", changed])
        #expect(try await fixture.details("topic").fingerprint == source.fingerprint)
        await expectReferenceError(.staleReference) { try await fixture.service.setUpstream(source, to: freshTarget) }
        #expect(try await fixture.details("topic").upstream == nil)
    }
}
