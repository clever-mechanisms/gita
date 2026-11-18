import AppKit
import Foundation
import GitaCore
import Testing

@testable import GitaUI

/// Each tab's Git commands: their responder follows the application in the responder chain, the menus reach it
/// with nil-targeted items, and the windows outside the tabs get their dependencies from the shell.
@MainActor
@Suite("App command responder", .serialized)
struct AppCommandResponderTests {
    private func launched() async throws -> (AppShellHarness, TemporaryRepository) {
        let repository = try TemporaryRepository()
        try repository.commit("README.md", "one\n", message: "First")
        let shell = AppShellHarness(arguments: ["Gita", "--repository", repository.url.path])
        await shell.launch(waitingFor: repository.url)
        return (shell, repository)
    }

    @Test func theSelectedTabsCommandsFollowTheApplicationInTheResponderChain() async throws {
        let (shell, repository) = try await launched()
        let responder = shell.app.commands
        #expect(responder.model === shell.app.model)
        #expect(shell.app.commands === responder)
        #expect(NSApp.nextResponder === responder)
        #expect(shell.app.repositoryController?.commands === responder)
        #expect(NSApp.target(forAction: #selector(RepositoryCommandResponder.fetch)) as AnyObject? === responder)

        let model = shell.app.model
        let head = try #require(model.snapshot?.commits.first)
        model.select(head)
        await appWaitUntil { model.selectedCommit?.id == head.id }
        let copy = try #require(shell.menuItem(#selector(RepositoryCommandResponder.copyCommit)))
        #expect(copy.target == nil)
        #expect(responder.validateMenuItem(copy))
        #expect(NSApp.sendAction(#selector(RepositoryCommandResponder.copyCommit), to: nil, from: copy))
        #expect(shell.recorder.pasteboard.string(forType: .string) == head.id)

        shell.tearDown()
        #expect(NSApp.nextResponder == nil)
        _ = repository
    }

    @Test func menuItemsTargetTheShellOnlyForItsOwnCommands() async throws {
        let (shell, repository) = try await launched()
        defer {
            shell.tearDown()
            _ = repository
        }
        let fetch = try #require(shell.menuItem(#selector(RepositoryCommandResponder.fetch)))
        #expect(fetch.target == nil)
        let settings = try #require(shell.menuItem(#selector(AppDelegate.settings)))
        #expect(settings.target === shell.app)
        #expect(AppDelegate.command(for: #selector(RepositoryCommandResponder.abortOperation)) == .abortOperation)
        #expect(AppDelegate.command(for: #selector(AppDelegate.settings)) == nil)
    }

    @Test func aResponderWithoutItsShellDoesNothing() async throws {
        let (shell, repository) = try await launched()
        defer {
            shell.tearDown()
            _ = repository
        }
        let orphan = RepositoryCommandResponder(model: shell.app.model, host: AppShellHarness().app)
        let item = NSMenuItem(title: "", action: #selector(RepositoryCommandResponder.fetch), keyEquivalent: "")
        #expect(orphan.host == nil)
        #expect(!orphan.validateMenuItem(item))
        orphan.reveal()
        orphan.openRemote()
        orphan.manageRemotes()
        #expect(shell.recorder.revealed.isEmpty)
    }

    @Test func theToolbarSettingsAndActivityGetTheShell() async throws {
        let (shell, repository) = try await launched()
        defer {
            shell.tearDown()
            _ = repository
        }
        #expect(MainToolbar.host === shell.app)
        #expect(ActivityWindowController.followedModel() === shell.app.model)
        let hooks = SettingsWindowController.appHooks
        #expect(hooks.activeModel() === shell.app.model)
        #expect(!hooks.isLanguageRestarting())
        hooks.preferencesDidChange(false)

        let inert = SettingsAppHooks()
        #expect(inert.activeModel() == nil)
        #expect(!inert.isLanguageRestarting())
        inert.preferencesDidChange(true)
        inert.restartForLanguage()
    }
}
