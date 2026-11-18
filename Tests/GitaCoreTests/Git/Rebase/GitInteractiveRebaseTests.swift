import Foundation
import Testing

@testable import GitaCore

/// The native interactive rebase end to end in a temporary repository: the reviewed plan, Git running the approved
/// todo through the app's own editor, stops that resume or abort, and every refusal before Git starts.
@Suite(.serialized)
struct GitInteractiveRebaseTests {
    private struct Repository {
        let fixture: OperationFixture
        let bridge: RebaseEditorBridge
        let service: GitService
        let base: String
        let commits: [String]

        /// `base`, then three commits touching their own files.
        static func make() async throws -> Self {
            let fixture = try await OperationFixture()
            let bridge = try RebaseEditorBridge()
            try fixture.write("base.txt", "base\n")
            let base = try await fixture.commit("Base")
            var commits: [String] = []
            for name in ["one", "two", "three"] {
                try fixture.write(name + ".txt", name + "\n")
                commits.append(try await fixture.commit("Add " + name))
            }
            return Self(
                fixture: fixture, bridge: bridge, service: GitService(root: fixture.root, runner: bridge), base: base,
                commits: commits)
        }

        func remove() {
            fixture.remove()
            bridge.remove()
        }

        func subjects() async throws -> [String] {
            try await fixture.git(["log", "--format=%s"]).text.split(separator: "\n").map(String.init)
        }

        /// No owned session is left once the rebase is over.
        func sessionFolderIsGone() -> Bool {
            let container = fixture.root.appendingPathComponent(".git/" + RebaseSession.container)
            return (try? FileManager.default.contentsOfDirectory(atPath: container.path))?.isEmpty ?? true
        }
    }

    private func steps(
        _ commits: [String], _ actions: [GitRebaseAction], messages: [Int: String] = [:]
    ) -> [GitRebaseStep] {
        zip(commits.indices, zip(commits, actions)).map { index, pair in
            GitRebaseStep(commitID: pair.0, action: pair.1, message: messages[index])
        }
    }

    @Test func previewListsTheLinearRangeOldestFirst() async throws {
        let repository = try await Repository.make()
        defer { repository.remove() }
        let plan = try await repository.service.previewInteractiveRebase(after: repository.base)
        #expect(plan.base.id == repository.base)
        #expect(plan.headID == repository.commits.last)
        #expect(plan.branch == "main")
        #expect(plan.commits.map(\.id) == repository.commits)
        #expect(plan.commits.map(\.subject) == ["Add one", "Add two", "Add three"])
        #expect(try await repository.service.previewInteractiveRebase(after: repository.base).identity == plan.identity)
    }

    @Test func rewordFixupAndDropRewriteTheBranch() async throws {
        let repository = try await Repository.make()
        defer { repository.remove() }
        let plan = try await repository.service.previewInteractiveRebase(after: repository.base)
        let outcome = try await repository.service.startInteractiveRebase(
            plan, steps: steps(repository.commits, [.reword, .fixup, .drop], messages: [0: "Add one and two\n"]))
        completed(outcome)
        #expect(try await repository.subjects() == ["Add one and two", "Base"])
        let files = try await repository.fixture.git(["ls-files"]).text
        #expect(files == "base.txt\none.txt\ntwo.txt\n")
        #expect(try await repository.service.operationState() == nil)
        #expect(repository.sessionFolderIsGone())
    }

    @Test func anEditStopResumesThroughTheOwnedSession() async throws {
        let repository = try await Repository.make()
        defer { repository.remove() }
        let plan = try await repository.service.previewInteractiveRebase(after: repository.base)
        let outcome = try await repository.service.startInteractiveRebase(
            plan, steps: steps(repository.commits, [.pick, .edit, .pick]))
        let state = try stopped(outcome, kind: .rebase)
        #expect(state.isEditingCommit)
        try repository.fixture.write("two.txt", "two, amended\n")
        try await repository.fixture.git(["commit", "--quiet", "--all", "--amend", "--no-edit"])
        let resumed = try await repository.service.continueOperation(
            expected: try #require(try await repository.service.operationState()))
        completed(resumed)
        #expect(try await repository.subjects() == ["Add three", "Add two", "Add one", "Base"])
        #expect(try await repository.fixture.git(["show", "HEAD~1:two.txt"]).text == "two, amended\n")
    }

    @Test func aConflictStopCanBeAbortedBackToTheOriginalHead() async throws {
        let fixture = try await OperationFixture()
        let bridge = try RebaseEditorBridge()
        defer {
            fixture.remove()
            bridge.remove()
        }
        try fixture.write("file.txt", "base\n")
        let base = try await fixture.commit("Base")
        try fixture.write("file.txt", "first\n")
        let first = try await fixture.commit("First")
        try fixture.write("file.txt", "second\n")
        let second = try await fixture.commit("Second")
        let service = GitService(root: fixture.root, runner: bridge)
        let plan = try await service.previewInteractiveRebase(after: base)
        // Dropping the first change makes the second one conflict with the base.
        let outcome = try await service.startInteractiveRebase(
            plan, steps: [GitRebaseStep(commitID: first, action: .drop), GitRebaseStep(commitID: second)])
        let state = try stopped(outcome, kind: .rebase)
        #expect(!state.isEditingCommit)
        completed(try await service.abortOperation(expected: state))
        #expect(try await fixture.head() == second)
        #expect(try await service.operationState() == nil)
    }

    @Test func aStalePlanIsRefusedBeforeGitRuns() async throws {
        let repository = try await Repository.make()
        defer { repository.remove() }
        let plan = try await repository.service.previewInteractiveRebase(after: repository.base)
        try repository.fixture.write("four.txt", "four\n")
        let head = try await repository.fixture.commit("Add four")
        await expectError(RebasePlanError.staleReview) {
            _ = try await repository.service.startInteractiveRebase(
                plan, steps: steps(repository.commits, [.pick, .pick, .pick]))
        }
        #expect(try await repository.fixture.head() == head)
    }

    @Test func dirtyFilesMergesAndForeignRangesAreRefused() async throws {
        let repository = try await Repository.make()
        defer { repository.remove() }
        let service = repository.service
        await expectGitError(.invalidReference) { _ = try await service.previewInteractiveRebase(after: "main") }
        await expectError(RebaseHistoryError.noAncestor) {
            _ = try await service.previewInteractiveRebase(after: try #require(repository.commits.last))
        }
        try repository.fixture.write("one.txt", "dirty\n")
        await expectGitError(.dirtyTrackedFiles) {
            _ = try await service.previewInteractiveRebase(after: repository.base)
        }
        try await repository.fixture.git(["checkout", "--", "one.txt"])

        try await repository.fixture.git(["switch", "--quiet", "-c", "side", repository.base])
        try repository.fixture.write("side.txt", "side\n")
        try await repository.fixture.commit("Side")
        try await repository.fixture.git(["switch", "--quiet", "main"])
        try await repository.fixture.git(["merge", "--quiet", "--no-ff", "--no-edit", "side"])
        await expectError(RebaseHistoryError.nonlinearRange) {
            _ = try await service.previewInteractiveRebase(after: repository.base)
        }
        try Data().write(to: repository.fixture.root.appendingPathComponent(".git/BISECT_START"))
        await expectError(RebaseHistoryError.incompleteHistory) {
            _ = try await service.previewInteractiveRebase(after: try #require(repository.commits.first))
        }
    }

    @Test func plansMustNameEveryCommitOnceWithValidMessages() throws {
        let ids = (1...3).map { String(repeating: String($0), count: 40) }
        func check(_ steps: [GitRebaseStep]) -> String? {
            do {
                try RebaseSession.validateSteps(steps, originalIDs: ids)
                return nil
            } catch { return error.localizedDescription }
        }
        #expect(check(ids.map { GitRebaseStep(commitID: $0) }) == nil)
        #expect(check(Array(ids.dropLast()).map { GitRebaseStep(commitID: $0) }) != nil)
        #expect(
            check(
                [GitRebaseStep(commitID: ids[0], action: .reword)] + ids.dropFirst().map { GitRebaseStep(commitID: $0) }
            )
                == String(localized: "Enter a nonempty reword message of at most 64 KB."))
        #expect(
            check([GitRebaseStep(commitID: ids[0], message: "x")] + ids.dropFirst().map { GitRebaseStep(commitID: $0) })
                == String(localized: "Only Reword accepts a replacement message."))
        #expect(
            check(
                [GitRebaseStep(commitID: ids[0], action: .drop), GitRebaseStep(commitID: ids[1], action: .squash)]
                    + [GitRebaseStep(commitID: ids[2])])
                == String(localized: "Squash and Fixup need a preceding retained commit."))
    }

    @Test func gitVersionsIndexEntriesAndEditorInvocationsAreChecked() {
        #expect(GitService.isRebaseCapable(gitVersion: "git version 2.45.0"))
        #expect(GitService.isRebaseCapable(gitVersion: "git version 3.0.1 (Apple Git-200)"))
        #expect(!GitService.isRebaseCapable(gitVersion: "git version 2.39.5 (Apple Git-154)"))
        #expect(!GitService.isRebaseCapable(gitVersion: "git version"))
        let regular = Data("H 100644 \(String(repeating: "a", count: 40)) 0\tfile.txt".utf8)
        let skipped = Data("S 100644 \(String(repeating: "a", count: 40)) 0\tfile.txt".utf8)
        let module = Data("H 160000 \(String(repeating: "a", count: 40)) 0\tlib".utf8)
        #expect(GitService.isFullIndex(regular + Data([0]) + regular))
        #expect(!GitService.isFullIndex(skipped))
        #expect(!GitService.isFullIndex(module))
        // Session paths stay physical: `/private/var/…` is not rewritten to its `/var` symlink.
        #expect(RebaseFiles.lexicalPath(URL(fileURLWithPath: "/private/var/a/./b//c/../d")) == "/private/var/a/b/d")
        #expect(GitRebaseEditor.handleInvocation(arguments: ["app"]) == nil)
        #expect(GitRebaseEditor.handleInvocation(arguments: ["app", GitRebaseEditor.argument, "other"]) == 1)
        #expect(
            GitRebaseEditor.handleInvocation(
                arguments: ["app", GitRebaseEditor.argument, "sequence", "/tmp", UUID().uuidString, "/tmp/x"]) == 1)
    }
}
