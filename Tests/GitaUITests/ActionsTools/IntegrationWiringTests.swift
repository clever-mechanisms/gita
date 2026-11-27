import AppKit
import Foundation
import Testing

@testable import GitaCore
@testable import GitaUI

@Suite("0.3.0 Integration Wiring Regression Tests")
@MainActor
struct IntegrationWiringTests {
    @Test func externalDiffRequestHandlesStagedPartlyStagedCommitAndStash() async throws {
        let repo = try TemporaryRepository()
        let first = try repo.commit("note.txt", "base\n", message: "Base")
        let second = try repo.commit("note.txt", "head\n", message: "Head")
        let service = GitService(root: repo.url)

        try "staged\n".write(to: repo.url.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        try repo.git("add", "note.txt")
        try "working\n".write(to: repo.url.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)

        let staged = try await RepositoryViewController.buildExternalDiffRequest(
            service: service, root: repo.url, path: "note.txt", target: .staged)
        #expect(String(decoding: staged.leftContent, as: UTF8.self) == "head\n")
        #expect(String(decoding: staged.rightContent, as: UTF8.self) == "staged\n")
        #expect(staged.leftLabel == "HEAD")
        #expect(staged.rightLabel == "staged")

        let unstaged = try await RepositoryViewController.buildExternalDiffRequest(
            service: service, root: repo.url, path: "note.txt", target: .unstaged)
        #expect(String(decoding: unstaged.leftContent, as: UTF8.self) == "staged\n")
        #expect(String(decoding: unstaged.rightContent, as: UTF8.self) == "working\n")
        #expect(unstaged.leftLabel == "index")
        #expect(unstaged.rightLabel == "working")

        let commit = try await RepositoryViewController.buildExternalDiffRequest(
            service: service, root: repo.url, path: "note.txt", target: .commit(id: second, parent: first))
        #expect(String(decoding: commit.leftContent, as: UTF8.self) == "base\n")
        #expect(String(decoding: commit.rightContent, as: UTF8.self) == "head\n")

        try repo.git("stash", "push", "-m", "wip")
        let stash = try await RepositoryViewController.buildExternalDiffRequest(
            service: service, root: repo.url, path: "note.txt", target: .stash(ref: "stash@{0}", parent: "stash@{0}^"))
        #expect(String(decoding: stash.leftContent, as: UTF8.self) == "head\n")
        #expect(String(decoding: stash.rightContent, as: UTF8.self) == "working\n")
    }

    @Test func customActionLibraryCachesAndInvalidates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CustomActionStore(fileURL: directory.appendingPathComponent("actions.json"))
        let library = CustomActionLibrary(store: store)
        #expect(library.actions().isEmpty)

        let action = CustomAction(name: "Echo", scope: .repository, executable: "/bin/echo", arguments: ["$REPO_ROOT"])
        _ = try store.upsert(action)
        // Cached until invalidated.
        #expect(library.actions().isEmpty)

        library.invalidate()
        #expect(library.actions().count == 1)
        #expect(library.actions(for: .repository).count == 1)
        #expect(library.actions(for: .file).isEmpty)
    }

    @Test func inlineToolHostUnmountsPreviousControllerWhenSwitchingTools() async throws {
        let fixture = try await RepositoryWindowFixture()
        defer { fixture.close() }
        let controller = fixture.controller
        controller.openToolPage(.reflog(ref: "HEAD"))
        let first = try #require(controller.toolHost.activeController as? ReflogViewController)
        #expect(controller.model.section == .reflog)
        #expect(!controller.toolHost.container.isHidden)
        #expect(controller.prWorkspace.isHidden)

        controller.openToolPage(.codeSearch())
        let second = try #require(controller.toolHost.activeController as? CodeSearchViewController)
        #expect(first.parent == nil)
        #expect(second.parent === controller)
        #expect(controller.model.section == .codeSearch)
    }

    @Test func commitSigningRowHidesWhenUnconfiguredAndWithoutTemplate() {
        let unconfigured = CommitSigningRowState(
            signing: .loaded(
                CommitSigningConfig(isEnabled: false, isRepoLocalOverride: false, format: .openpgp, signingKey: nil)),
            template: nil)
        #expect(!unconfigured.shouldShow)

        let configured = CommitSigningRowState(
            signing: .loaded(
                CommitSigningConfig(isEnabled: false, isRepoLocalOverride: false, format: .ssh, signingKey: "key.pub")),
            template: nil)
        #expect(configured.shouldShow)

        let loading = CommitSigningRowState(signing: .loading, template: nil)
        #expect(!loading.shouldShow)
    }
}
