import Foundation
import Testing

@testable import GitaCore
@testable import GitaUI

@Suite("CommitDraftController")
@MainActor
struct ModelCommitDraftControllerTests {
    private struct Unreadable: Error {}

    private func snapshot(_ root: String) -> RepositorySnapshot {
        RepositorySnapshot(
            root: URL(fileURLWithPath: root), branch: "main", head: nil, changes: [], commits: [], references: [],
            worktrees: [], stashes: [], remoteURL: nil, gitDirectory: URL(fileURLWithPath: root + "/.git"))
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitaUITests-DraftController-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aDraftThatCannotOpenIsReportedOnce() {
        let controller = CommitDraftController { _, _ in throw Unreadable() }
        var failures: [CommitDraftController.Failure] = []
        controller.onFailure = { failures.append($0) }
        let snapshot = snapshot("/tmp/draft-\(UUID().uuidString)")
        #expect(controller.restore(for: snapshot))
        #expect(controller.restore(for: snapshot))
        #expect(failures.count == 1)
        #expect(failures.first?.alert != nil)
        #expect(controller.text.isEmpty)
        #expect(!controller.isCurrent)
    }

    @Test func editingHoldsANewWorktreeUntilItEnds() throws {
        let drafts = try folder()
        defer { try? FileManager.default.removeItem(at: drafts) }
        let controller = CommitDraftController { try CommitMessageDraft.open(root: $0, gitDirectory: $1, in: drafts) }
        let first = snapshot("/tmp/draft-a-\(UUID().uuidString)")
        let second = snapshot("/tmp/draft-b-\(UUID().uuidString)")
        #expect(controller.restore(for: first))
        controller.setText("Typed")
        controller.beginEditing()
        #expect(!controller.restore(for: second))
        #expect(controller.pendingIdentity)
        #expect(controller.endEditing())
        #expect(controller.restore(for: second))
        #expect(controller.text.isEmpty)
        #expect(controller.restore(for: first))
        #expect(controller.text == "Typed")
        controller.reset()
        #expect(controller.draft == nil)
    }

    @Test func aDraftThatCannotBeSavedBlocksLeavingIt() throws {
        let drafts = try folder()
        let controller = CommitDraftController { try CommitMessageDraft.open(root: $0, gitDirectory: $1, in: drafts) }
        var failures: [CommitDraftController.Failure] = []
        controller.onFailure = { failures.append($0) }
        #expect(controller.restore(for: snapshot("/tmp/draft-c-\(UUID().uuidString)")))
        try FileManager.default.removeItem(at: drafts)
        try Data().write(to: drafts) // a file where the folder was: saving fails
        defer { try? FileManager.default.removeItem(at: drafts) }
        controller.setText("Unsaved")
        #expect(!controller.flush())
        #expect(failures.last?.alert != nil)
        #expect(!controller.restore(for: snapshot("/tmp/draft-d-\(UUID().uuidString)")))
    }

    @Test func theAppsDependenciesAreBuilt() {
        let standard = AppModelDependencies.standard
        _ = standard.vercelActions
    }
}
