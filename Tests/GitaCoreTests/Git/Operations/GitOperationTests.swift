import Darwin
import Foundation
import Testing

@testable import GitaCore

@Suite(.serialized)
struct GitOperationTests {
    @Test func cleanMergeModesPreserveUntrackedFilesAndIgnoreImplicitSquashConfig() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        try fixture.write("base.txt", "base\n")
        try await fixture.commit("Base")
        try await fixture.git(["switch", "-c", "incoming"])
        try fixture.write("incoming.txt", "new\n")
        try await fixture.commit("Incoming")
        try await fixture.git(["switch", "main"])
        try fixture.write("untracked.txt", "preserve\n")
        try await fixture.git(["config", "branch.main.mergeOptions", "--squash --no-commit"])
        completed(try await fixture.service.merge(ref: "incoming", mode: .noFastForward))
        let commit = try await fixture.service.commitDetails(ref: "HEAD")
        #expect(commit.commit.parents.count == 2)
        #expect(try await fixture.service.operationState() == nil)
        #expect(
            try String(contentsOf: fixture.root.appendingPathComponent("untracked.txt"), encoding: .utf8)
                == "preserve\n")
        #expect(try await fixture.service.snapshot().changes.map(\.path) == ["untracked.txt"])
        try await fixture.git(["config", "--unset", "branch.main.mergeOptions"])
        try await fixture.git(["switch", "incoming"])
        completed(try await fixture.service.merge(ref: "main", mode: .fastForwardOnly))
        #expect(try await fixture.head() == commit.commit.id)
    }

    @Test func mergeEditorReadsThreeVersionsAndContinuesWithoutASecondCommitAction() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        try await fixture.diverge(path: "space\tline\nfile.txt")
        let state = try stopped(try await fixture.service.merge(ref: "incoming"), kind: .merge)
        #expect(try await fixture.service.snapshot().operation == state)
        let document = try await fixture.service.conflict(path: "space\tline\nfile.txt")
        #expect(document.base?.text == "base\n")
        #expect(document.ours?.text == "current\n")
        #expect(document.theirs?.text == "incoming\n")
        #expect(document.isEditable)
        await expectGitError(.unresolvedConflicts) { _ = try await fixture.service.continueOperation(expected: state) }
        await expectGitError(.unresolvedMarkers) {
            try await fixture.service.resolveConflict(
                document, resolution: .edited("<<<<<<< current\ncurrent\n=======\nincoming\n>>>>>>> other\n"))
        }
        try await fixture.service.resolveConflict(document, resolution: .edited("combined\n"))
        #expect(try await fixture.service.operationState()?.identity == state.identity)
        await expectGitError(.operationActive) { try await fixture.service.commit(message: "Wrong path") }
        completed(try await fixture.service.continueOperation(expected: state))
        #expect(try await fixture.service.operationState() == nil)
        #expect(try await fixture.service.commitDetails(ref: "HEAD").commit.parents.count == 2)
        #expect(try await fixture.service.file(commit: "HEAD", path: document.path) == "combined\n")
    }

    @Test func rebaseShowsOntoAsOursAndDoesNotUpdateOtherBranches() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        let commits = try await fixture.diverge()
        try await fixture.git(["branch", "preserve-original", commits.current])
        try await fixture.git(["config", "rebase.updateRefs", "true"])
        try await fixture.git(["config", "rebase.autoStash", "true"])
        let state = try stopped(try await fixture.service.rebase(onto: "incoming"), kind: .rebase)
        #expect(state.step == 1 && state.total == 1 && state.branch == "main")
        let document = try await fixture.service.conflict(path: "file.txt")
        #expect(document.ours?.text == "incoming\n")
        #expect(document.theirs?.text == "current\n")
        try await fixture.service.resolveConflict(document, resolution: .edited("combined replay\n"))
        #expect(try await fixture.service.operationState()?.identity == state.identity)
        completed(try await fixture.service.continueOperation(expected: state))
        #expect(
            try await fixture.git(["rev-parse", "preserve-original"]).text.trimmingCharacters(in: .newlines)
                == commits.current)
        #expect(try await fixture.service.commitDetails(ref: "HEAD").commit.parents == [commits.incoming])
        #expect(try await fixture.service.snapshot().branch == "main")
    }

    @Test func cherryPickSkipAbortAndStaleOperationGuardPreserveBranch() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        let commits = try await fixture.diverge()
        let first = try stopped(try await fixture.service.cherryPick(commit: commits.incoming), kind: .cherryPick)
        completed(try await fixture.service.skipOperation(expected: first))
        #expect(try await fixture.head() == commits.current)
        let second = try stopped(try await fixture.service.cherryPick(commit: commits.incoming), kind: .cherryPick)
        #expect(first.identity != second.identity)
        await expectGitError(.operationChanged) { _ = try await fixture.service.abortOperation(expected: first) }
        #expect(try await fixture.service.operationState() == second)
        completed(try await fixture.service.abortOperation(expected: second))
        #expect(try await fixture.head() == commits.current)
        #expect(try await fixture.service.snapshot().changes.isEmpty)
    }

    @Test func revertConflictCanContinueAndCleanRevertCanFinish() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        try fixture.write("file.txt", "base\n")
        try await fixture.commit("Base")
        try fixture.write("file.txt", "change\n")
        let target = try await fixture.commit("Change")
        try fixture.write("file.txt", "later\n")
        try await fixture.commit("Later")
        let state = try stopped(try await fixture.service.revert(commit: target), kind: .revert)
        let document = try await fixture.service.conflict(path: "file.txt")
        #expect(document.theirs?.text == "base\n")
        try await fixture.service.resolveConflict(document, resolution: .theirs)
        completed(try await fixture.service.continueOperation(expected: state))
        #expect(try await fixture.service.file(commit: "HEAD", path: "file.txt") == "base\n")
        let reverted = try await fixture.head()
        completed(try await fixture.service.revert(commit: reverted))
        #expect(try await fixture.service.file(commit: "HEAD", path: "file.txt") == "later\n")
    }

    @Test func dirtyTrackedFilesAndOperationOverlapAreRefusedBeforeMutation() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        let commits = try await fixture.diverge()
        try fixture.write("file.txt", "dirty\n")
        await expectGitError(.dirtyTrackedFiles) { _ = try await fixture.service.merge(ref: "incoming") }
        try fixture.write("file.txt", "current\n")
        let state = try stopped(try await fixture.service.merge(ref: "incoming"), kind: .merge)
        await expectGitError(.operationActive) { try await fixture.service.checkout(ref: "incoming") }
        await expectGitError(.operationActive) { try await fixture.service.createBranch(name: "unwanted") }
        await expectGitError(.operationActive) {
            _ = try await fixture.service.pull(GitPullRequest(remote: "origin", branch: "main", autostash: true))
        }
        await expectGitError(.operationActive) { _ = try await fixture.service.cherryPick(commit: commits.incoming) }
        completed(try await fixture.service.abortOperation(expected: state))
        #expect(try await fixture.head() == commits.current)
        #expect(try await fixture.service.snapshot().changes.isEmpty)
    }

    @Test func changedOperationContextAndHeadInvalidateAnOtherwiseIdenticalConflict() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        let commits = try await fixture.diverge()
        _ = try stopped(try await fixture.service.merge(ref: "incoming"), kind: .merge)
        let merge = try await fixture.service.conflict(path: "file.txt")
        let mergeHead = fixture.root.appendingPathComponent(".git/MERGE_HEAD")
        let cherryHead = fixture.root.appendingPathComponent(".git/CHERRY_PICK_HEAD")
        try FileManager.default.moveItem(at: mergeHead, to: cherryHead)
        #expect(try await fixture.service.operationState()?.kind == .cherryPick)
        await expectGitError(.staleConflict) { try await fixture.service.resolveConflict(merge, resolution: .theirs) }
        try FileManager.default.removeItem(at: cherryHead)
        let noOperation = try await fixture.service.conflict(path: "file.txt")
        try await fixture.git(["update-ref", "HEAD", commits.incoming])
        await expectGitError(.staleConflict) {
            try await fixture.service.resolveConflict(noOperation, resolution: .ours)
        }
    }

    @Test func cleanCherryPickAndMergeMainlinesAreExplicit() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        try fixture.write("base.txt", "base\n")
        let base = try await fixture.commit("Base")
        try await fixture.git(["switch", "-c", "incoming"])
        try fixture.write("incoming.txt", "incoming\n")
        let incoming = try await fixture.commit("Incoming")
        try await fixture.git(["switch", "main"])
        try fixture.write("main.txt", "main\n")
        try await fixture.commit("Main")
        completed(try await fixture.service.cherryPick(commit: incoming))
        #expect(try await fixture.service.file(commit: "HEAD", path: "incoming.txt") == "incoming\n")
        #expect(try await fixture.service.operationState() == nil)
        completed(try await fixture.service.merge(ref: "incoming", mode: .noFastForward))
        let merge = try await fixture.head()
        #expect(try await fixture.service.commitDetails(ref: merge).commit.parents.count == 2)
        try await fixture.git(["switch", "-c", "pick-merge", base])
        do {
            _ = try await fixture.service.cherryPick(commit: merge)
            Issue.record("Merge pick must require a parent")
        } catch { #expect(error.localizedDescription.contains("mainline parent")) }
        completed(try await fixture.service.cherryPick(commit: merge, mainline: 2))
        #expect(try await fixture.service.file(commit: "HEAD", path: "main.txt") == "main\n")
        completed(try await fixture.service.revert(commit: "HEAD"))
        #expect(try await fixture.service.tree(commit: "HEAD").map(\.path) == ["base.txt"])
    }

    @Test func multiCommitSequencerMovesIdentityBetweenConflictedSteps() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        try fixture.write("first.txt", "base first\n")
        try fixture.write("second.txt", "base second\n")
        try await fixture.commit("Base")
        try await fixture.git(["switch", "-c", "incoming"])
        try fixture.write("first.txt", "incoming first\n")
        let first = try await fixture.commit("First")
        try fixture.write("second.txt", "incoming second\n")
        let second = try await fixture.commit("Second")
        try await fixture.git(["switch", "main"])
        try fixture.write("first.txt", "current first\n")
        try fixture.write("second.txt", "current second\n")
        try await fixture.commit("Current")
        let start = try await fixture.git(["cherry-pick", first, second], allowFailure: true)
        #expect(start.exitCode != 0)
        let before = try #require(try await fixture.service.operationState())
        #expect(before.kind == .cherryPick)
        let document = try await fixture.service.conflict(path: "first.txt")
        try await fixture.service.resolveConflict(document, resolution: .theirs)
        let after = try stopped(try await fixture.service.continueOperation(expected: before), kind: .cherryPick)
        #expect(after.identity != before.identity)
        await expectGitError(.operationChanged) { _ = try await fixture.service.abortOperation(expected: before) }
        #expect(try await fixture.service.snapshot().changes.contains { $0.path == "second.txt" && $0.isConflict })
        completed(try await fixture.service.skipOperation(expected: after))
        #expect(try await fixture.service.file(commit: "HEAD", path: "first.txt") == "incoming first\n")
        #expect(try await fixture.service.file(commit: "HEAD", path: "second.txt") == "current second\n")
    }

    @Test func externalAmAndLinkedWorktreeStatesAreDetectedInTheirOwnGitDirectories() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        let commits = try await fixture.diverge()
        let patch = try await fixture.git(["format-patch", "-1", "--stdout", commits.incoming]).stdout
        let patchURL = fixture.container.appendingPathComponent("incoming.patch")
        try patch.write(to: patchURL)
        let started = try await fixture.git(["am", "--3way", patchURL.path], allowFailure: true)
        #expect(started.exitCode != 0)
        let state = try #require(try await fixture.service.operationState())
        #expect(state.kind == .apply && state.step == 1 && state.total == 1)
        let document = try await fixture.service.conflict(path: "file.txt")
        try await fixture.service.resolveConflict(document, resolution: .edited("mail resolved\n"))
        completed(try await fixture.service.continueOperation(expected: state))
        let linked = fixture.container.appendingPathComponent("linked")
        try await fixture.git(["worktree", "add", "-b", "linked", linked.path, commits.current])
        let service = GitService(root: linked)
        let linkedState = try stopped(try await service.merge(ref: commits.incoming), kind: .merge)
        #expect(try await service.snapshot().operation == linkedState)
        #expect(try await fixture.service.operationState() == nil)
        completed(try await service.abortOperation(expected: linkedState))
        #expect(try await service.snapshot().changes.isEmpty)
    }

    @Test func rebaseSessionPathsArePhysicalForTheNoFollowWalk() async throws {
        // Foundation rewrites /private/var/... to the /var symlink, which the session's
        // per-component no-follow walk refuses. Git reports and passes physical paths.
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        let gitDirectory = try await fixture.git(["rev-parse", "--absolute-git-dir"]).text.trimmingCharacters(
            in: .newlines)
        let foundation = URL(fileURLWithPath: gitDirectory).resolvingSymlinksInPath()
        let physical = try GitService.physicalDirectory(gitDirectory)
        #expect(physical.path.hasPrefix("/private/"))
        #expect(foundation.path != physical.path)
        #expect(throws: (any Error).self) { _ = try RebaseFiles.directoryIdentity(foundation) }
        _ = try RebaseFiles.directoryIdentity(physical)
        #expect(throws: (any Error).self) { _ = try GitService.physicalDirectory("relative/path") }
    }

    @Test func rebaseAbortAndSkipDoNotRewriteOtherRefsOrLeaveSequencerState() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        let commits = try await fixture.diverge()
        let first = try stopped(try await fixture.service.rebase(onto: "incoming"), kind: .rebase)
        completed(try await fixture.service.abortOperation(expected: first))
        #expect(try await fixture.head() == commits.current)
        let second = try stopped(try await fixture.service.rebase(onto: "incoming"), kind: .rebase)
        completed(try await fixture.service.skipOperation(expected: second))
        #expect(try await fixture.head() == commits.incoming)
        #expect(try await fixture.service.operationState() == nil)
        #expect(try await fixture.service.snapshot().branch == "main")
    }

    @Test func incompleteExternalSequencePreventsAnotherOperation() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        let commits = try await fixture.diverge()
        let sequence = fixture.root.appendingPathComponent(".git/sequencer")
        try FileManager.default.createDirectory(at: sequence, withIntermediateDirectories: false)
        do {
            _ = try await fixture.service.merge(ref: "incoming")
            Issue.record("Incomplete sequence must block a new operation")
        } catch { #expect(error.localizedDescription.contains("incomplete Git sequence")) }
        #expect(try await fixture.head() == commits.current)
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent("file.txt")) == Data("current\n".utf8))
        try fixture.write(".git/sequencer/todo", "unknown pending command\n")
        do {
            _ = try await fixture.service.operationState()
            Issue.record("Unknown sequence must not be treated as absent")
        } catch { #expect(error.localizedDescription.contains("unsupported Git sequence")) }
    }
}
