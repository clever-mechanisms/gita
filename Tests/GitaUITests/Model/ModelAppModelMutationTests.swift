import Foundation
import Testing

@testable import GitaCore
@testable import GitaUI

@Suite("AppModel Git mutations on a disposable repository")
@MainActor
struct ModelAppModelMutationTests {
    private func opened(_ setUp: (TemporaryRepository) throws -> Void = { _ in }) async throws -> ModelHarness {
        let harness = try ModelHarness()
        try harness.repository.commit("a.txt", "a\n", message: "First")
        try setUp(harness.repository)
        try await harness.open()
        return harness
    }

    @Test func stageAndCommitThroughPerform() async throws {
        let harness = try await opened { try $0.write("a.txt", "edited\n") }
        let model = harness.model
        var succeeded = false
        model.perform(
            "Stage", onSuccess: { succeeded = true }, operation: { try await $0.stage(paths: ["a.txt"]) })
        #expect(model.isMutating)
        #expect(model.status == String(localized: "\("Stage")…"))
        model.perform("Ignored while busy") { _ in }
        try await harness.settle { model.hasStagedChanges }
        #expect(succeeded)

        model.perform("Commit") { try await $0.commit(message: "Edited") }
        try await harness.settle { model.snapshot?.commits.first?.subject == "Edited" }
        #expect(model.status == RepositoryStatusText.clean.rawValue)
        #expect(model.events.contains { $0.title == "Commit" && !$0.failed })
        #expect(model.lastMutation?.title == "Commit")
        #expect(model.lastMutation?.outcome == .completed)
        #expect(model.lastMutation?.isRecent() == true)
        #expect(model.lastMutation?.isRecent(at: Date().addingTimeInterval(MutationResult.shownFor + 1)) == false)
    }

    @Test func aFailedMutationIsLoggedAndShown() async throws {
        let harness = try await opened()
        harness.model.perform("Checkout") { try await $0.checkout(ref: "no-such-branch") }
        try await harness.settle()
        #expect(harness.recorder.errors == ["Checkout"])
        #expect(harness.model.events.first?.failed == true)
        #expect(harness.model.lastMutation?.outcome == .failed)
    }

    @Test func aMergeConflictStopsOnTheChangesPageAndResolves() async throws {
        let harness = try await opened { repository in
            try repository.git("checkout", "-q", "-b", "feature")
            try repository.commit("a.txt", "feature\n", message: "Feature")
            try repository.git("checkout", "-q", "main")
            try repository.commit("a.txt", "main\n", message: "Main")
        }
        let model = harness.model
        model.performGitOperation("Merge") { try await $0.merge(ref: "feature") }
        try await harness.settle { model.snapshot?.operation != nil }
        #expect(model.section == .changes)
        #expect(model.lastMutation?.outcome == .paused)
        #expect(model.hasConflicts)
        #expect(!model.canStartOperation)

        let service = try #require(model.service)
        let document = try await service.conflict(path: "a.txt")
        try await model.resolveConflict(document, resolution: .theirs, using: service)
        try await harness.settle { !model.hasConflicts }
        #expect(model.events.contains { $0.title == String(localized: "Resolved conflict") })

        let other = GitService(root: harness.url)
        await #expect(throws: StaleStateError.repositoryChanged(.conflict)) {
            try await model.resolveConflict(document, resolution: .ours, using: other)
        }
    }

    @Test func aCompletedOperationIsLogged() async throws {
        let harness = try await opened { repository in
            try repository.git("checkout", "-q", "-b", "feature")
            try repository.commit("b.txt", "b\n", message: "Feature")
            try repository.git("checkout", "-q", "main")
        }
        harness.model.performGitOperation("Merge") { try await $0.merge(ref: "feature") }
        try await harness.settle { harness.model.snapshot?.commits.first?.subject == "Feature" }
        #expect(harness.model.section == .history)

        harness.model.performGitOperation("Merge") { try await $0.merge(ref: "missing") }
        try await harness.settle()
        #expect(harness.recorder.errors == ["Merge"])
    }

    @Test func reviewedReferenceAndRemoteActions() async throws {
        let harness = try await opened { try $0.git("branch", "topic") }
        let model = harness.model
        let service = try #require(model.service)
        let head = try #require(model.snapshot?.head)

        try await model.applyReference(.createTag(name: "v1", commitID: head, annotation: nil), using: service)
        try await harness.settle { model.snapshot?.references.contains { $0.fullName == "refs/tags/v1" } == true }

        let topic = try await service.referenceDetails(fullName: "refs/heads/topic")
        try await model.applyReference(.renameBranch(topic, "renamed"), using: service)
        try await harness.settle { model.snapshot?.references.contains { $0.fullName == "refs/heads/renamed" } == true }

        let stale = topic
        await #expect(throws: (any Error).self) {
            try await model.applyReference(.deleteBranch(stale), using: service)
        }
        #expect(model.events.first?.failed == true)

        try await model.applyRemote(.add(name: "origin", url: "https://example.invalid/repo.git"), using: service)
        try await harness.settle { model.snapshot?.remoteURL == "https://example.invalid/repo.git" }
        let remote = try #require(try await service.remoteDetails().first)
        try await model.applyRemote(.rename(remote, "upstream"), using: service)
        try await harness.settle()
        #expect(model.events.first?.title == RemoteManagementAction.rename(remote, "upstream").localizedTitle)

        let other = GitService(root: harness.url)
        await #expect(throws: StaleStateError.repositoryChanged(.action)) {
            try await model.applyRemote(.remove(remote), using: other)
        }
    }

    @Test func actionTitles() {
        let details = GitReferenceDetails.testValue
        let remote = GitRemoteDetails.testValue
        let titles = [
            ReferenceReviewAction.renameBranch(details, "x").localizedTitle,
            ReferenceReviewAction.deleteBranch(details).localizedTitle,
            ReferenceReviewAction.setUpstream(details, nil).localizedTitle,
            ReferenceReviewAction.setUpstream(details, details).localizedTitle,
            ReferenceReviewAction.createTag(name: "t", commitID: "c", annotation: nil).localizedTitle,
            ReferenceReviewAction.deleteTag(details).localizedTitle,
            RemoteManagementAction.add(name: "o", url: "u").localizedTitle,
            RemoteManagementAction.setURL(remote, "u").localizedTitle,
            RemoteManagementAction.rename(remote, "n").localizedTitle,
            RemoteManagementAction.remove(remote).localizedTitle,
            RemoteManagementAction.fetch(remote).localizedTitle,
        ]
        #expect(Set(titles).count == titles.count)
    }

    @Test func softAndMixedResetsShowTheChangesPage() async throws {
        let harness = try await opened { try $0.commit("b.txt", "b\n", message: "Second") }
        let model = harness.model
        let service = try #require(model.service)
        let first = try harness.commit("First")

        let soft = try await service.resetPreview(to: first.id)
        try await model.applyReset(soft, mode: .soft, using: service)
        #expect(model.section == .changes)
        #expect(model.staged)
        try await harness.settle { model.hasStagedChanges }

        model.section = .history
        try harness.repository.git("commit", "-q", "-m", "Again")
        model.refresh()
        try await harness.settle { model.snapshot?.commits.first?.subject == "Again" }
        let hard = try await service.resetPreview(to: first.id)
        try await model.applyReset(hard, mode: .hard, using: service)
        #expect(model.section == .history)
        try await harness.settle { model.snapshot?.commits.first?.subject == "First" }
    }

    @Test func aRefusedInteractiveRebaseIsLoggedAndThrown() async throws {
        let harness = try await opened { try $0.commit("b.txt", "b\n", message: "Second") }
        let model = harness.model
        let service = try #require(model.service)
        let first = try harness.commit("First")
        let plan = try await service.previewInteractiveRebase(after: first.id)
        await #expect(throws: (any Error).self) {
            try await model.applyInteractiveRebase(plan, steps: [], using: service)
        }
        #expect(model.events.first?.title == String(localized: "Interactive rebase failed"))
        #expect(!model.isMutating)

        let other = GitService(root: harness.url)
        await #expect(throws: StaleStateError.repositoryChanged(.rebasePlan)) {
            try await model.applyInteractiveRebase(plan, steps: [], using: other)
        }
    }

    @Test func initializeAndCloneOpenTheResult() async throws {
        let harness = try ModelHarness()
        let model = harness.model
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitaUITests-Acquire-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        let created = scratch.appendingPathComponent("created", isDirectory: true)
        model.acquire(remote: nil, destination: created)
        #expect(model.isMutating)
        model.acquire(remote: nil, destination: created) // one at a time
        try await harness.settle { model.root?.lastPathComponent == "created" && model.snapshot != nil }

        let source = try TemporaryRepository()
        try source.commit("s.txt", "s\n", message: "Source")
        let cloned = scratch.appendingPathComponent("cloned", isDirectory: true)
        model.acquire(remote: source.url.path, destination: cloned)
        try await harness.settle { model.root?.lastPathComponent == "cloned" && model.snapshot != nil }
        #expect(model.snapshot?.commits.map(\.subject) == ["Source"])

        model.acquire(remote: scratch.appendingPathComponent("missing").path, destination: cloned)
        try await harness.settle { !harness.recorder.errors.isEmpty }
        #expect(harness.recorder.errors == [String(localized: "Clone repository")])
        #expect(model.statusIsFailure)
    }

    @Test func theCommitDraftFollowsTheWorktree() async throws {
        let harness = try await opened()
        let model = harness.model
        var drafts = 0
        model.observe { if $0 == .commitDraft { drafts += 1 } }
        model.beginEditingCommitMessage()
        model.setCommitMessage("Message")
        #expect(model.commitMessage == "Message")
        #expect(model.commitDraft?.text == "Message")
        #expect(drafts > 0)
        model.endEditingCommitMessage()
        #expect(model.flushCommitDraft())

        // Reopened: the same worktree finds the saved draft again.
        model.open(harness.url)
        try await harness.settle { model.snapshot != nil }
        #expect(model.commitMessage == "Message")
    }
}

extension GitReferenceDetails {
    fileprivate static let testValue = Self(
        root: URL(fileURLWithPath: "/tmp/repository"),
        reference: GitReference(name: "topic", fullName: "refs/heads/topic", commit: "abc", kind: .branch),
        objectID: "abc", objectType: "commit", fingerprint: "f")
}

extension GitRemoteDetails {
    fileprivate static let testValue = Self(
        name: "origin", fetchURLs: [], pushURLs: [], editableURL: nil, identity: "origin")
}

@Suite struct ModelStaleStateErrorTests {
    @Test func everyCaseKeepsItsMessage() {
        let cases: [(StaleStateError, String)] = [
            (.repositoryChanged(.conflict), String(localized: "The repository changed. Reopen the conflict.")),
            (
                .repositoryChanged(.referenceAction),
                String(localized: "The repository changed. Reopen the reference action.")
            ),
            (.repositoryChanged(.rebasePlan), String(localized: "The repository changed. Reopen the rebase plan.")),
            (.repositoryChanged(.action), String(localized: "The repository changed. Reopen this action.")),
            (.operationChanged, String(localized: "The operation changed. Select the conflict again.")),
            (.branchChanged, String(localized: "The current branch changed. Review the operation again.")),
            (.worktreeChanged, String(localized: "This worktree changed. Review it again before removing it.")),
            (.pathMoved, String(localized: "This path now belongs to a different repository.")),
            (
                .providerConnectionChanged,
                String(
                    localized: "The provider connection for this result changed. Refresh Connections before opening it."
                )
            ),
            (.busy, String(localized: "Wait for the current Git action to finish.")),
        ]
        for (error, message) in cases {
            #expect(error.errorDescription == message)
        }
    }
}
