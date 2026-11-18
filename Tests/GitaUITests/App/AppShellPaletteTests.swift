import AppKit
import Foundation
import GitaCore
import Testing

@testable import GitaUI

/// The command palette in the app shell: what it lists for a real repository and what choosing does.
@MainActor
@Suite("App shell · command palette", .serialized)
struct AppShellPaletteTests {
    private func launched(_ repository: TemporaryRepository) async -> AppShellHarness {
        let shell = AppShellHarness(arguments: ["Gita", "--repository", repository.url.path])
        await shell.launch(waitingFor: repository.url)
        return shell
    }

    private func repository() throws -> TemporaryRepository {
        let repository = try TemporaryRepository()
        try repository.commit("README.md", "one\n", message: "First")
        try repository.commit("README.md", "two\n", message: "Second")
        return repository
    }

    private func items(_ palette: PaletteController) -> [PaletteItem] { palette.state.entries.map(\.item) }

    private func type(_ text: String, _ palette: PaletteController) {
        palette.field.stringValue = text
        palette.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    }

    private func pressReturn(_ palette: PaletteController) {
        _ = palette.control(
            palette.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
    }

    @Test func itListsTheMenusTheRepositoryAndTheSettings() async throws {
        let repository = try repository()
        let shell = await launched(repository)
        defer { shell.tearDown() }
        let head = try #require(shell.app.model.snapshot?.head)
        shell.app.model.publish(ProviderSamples.github(head: head, branch: "main"))
        shell.app.showCommandPalette()
        let palette = try #require(shell.app.palette)
        defer { palette.close() }
        #expect(palette.state.scope == nil && palette.panel.parent === shell.app.mainWindow)
        let all = items(palette)
        let commands = all.filter { $0.kind == .command }
        for title in ["New Branch", "Push", "Workflows", "Show Terminal", "Sidebar", "Open in Finder", "Appearance"] {
            #expect(commands.contains { $0.title == title }, "\(title)")
        }
        #expect(
            !commands.contains {
                [
                    "Command Palette", "Open Recent", "Copy", "Passwords", "Credit Cards", "Emoji & Symbols",
                    "Start Dictation",
                ].contains($0.title)
            })
        #expect(commands.first { $0.title == "New Branch" }?.isEnabled == true)
        #expect(commands.first { $0.title == "Continue Operation" }?.isEnabled == false)
        #expect(commands.first { $0.title == "Push" }?.trailing == "⇧⌘P")
        #expect(all.filter { $0.kind == .commit }.map(\.title) == ["Second", "First"])
        #expect(all.contains { $0.kind == .branch && $0.title == "main" && $0.isCurrent })
        #expect(all.contains { $0.kind == .repository && $0.isCurrent })
        #expect(all.contains { $0.kind == .workspace && $0.isCurrent })
        #expect(all.contains { $0.kind == .pullRequest } && all.contains { $0.kind == .workflow })
        type("go to workflows", palette)
        #expect(palette.state.selectedItem?.title == "Workflows")
        type("open terminal", palette)
        #expect(palette.state.selectedItem?.title.contains("Terminal") == true)
    }

    @Test func choosingRunsCommandsCommitsAndPages() async throws {
        let repository = try repository()
        let shell = await launched(repository)
        defer { shell.tearDown() }
        let head = try #require(shell.app.model.snapshot?.head)
        shell.app.model.publish(ProviderSamples.github(head: head, branch: "main"))
        shell.app.showCommandPalette()
        var palette = try #require(shell.app.palette)
        type("new branch", palette)
        pressReturn(palette)
        #expect(shell.alerts.last?.messageText == String(localized: "New branch"))
        shell.alerts.answer(.alertSecondButtonReturn)
        #expect(Preference.paletteRecents.strings(shell.defaults).first?.hasPrefix("command.newBranch") == true)

        shell.app.showCommandPalette()
        palette = try #require(shell.app.palette)
        type("first", palette)
        #expect(palette.state.selectedItem?.kind == .commit)
        pressReturn(palette)
        await appWaitUntil { shell.app.model.selectedCommit?.subject == "First" }

        shell.app.showCommandPalette()
        palette = try #require(shell.app.palette)
        let pullRequest = try #require(items(palette).first { $0.kind == .pullRequest })
        shell.app.run(pullRequest)
        #expect(shell.app.model.section == .pullRequests)
        let pages = try #require(items(palette).first { $0.title == "Changes" })
        shell.app.run(pages)
        #expect(shell.app.model.section == .changes)
        let unavailable = try #require(items(palette).first { $0.title == "Continue Operation" })
        shell.app.run(unavailable)
        #expect(shell.recorder.beeps == 1)
        palette.close()
    }

    @Test func theWindowsOwnActionsAreCommandsToo() async throws {
        let repository = try repository()
        try repository.git("remote", "add", "origin", "git@github.com:example/fixture.git")
        let shell = await launched(repository)
        defer { shell.tearDown() }
        shell.app.showCommandPalette()
        var palette = try #require(shell.app.palette)
        let command = { (title: String) in self.items(palette).first { $0.kind == .command && $0.title == title } }
        // Never chosen here: it would call `gh`.
        #expect(command("Create PR")?.isEnabled == true && command("Create PR")?.detail == "Repository")
        #expect(command("Stage all")?.isEnabled == false && command("Commit staged")?.isEnabled == false)
        type("pull request", palette)
        #expect(palette.state.rows.contains { $0.result?.item.title == "Create PR" })
        palette.close()

        try repository.write("README.md", "changed\n")
        shell.app.refresh()
        await appWaitUntil { shell.app.model.snapshot?.changes.isEmpty == false }
        shell.app.showCommandPalette()
        palette = try #require(shell.app.palette)
        let stage = try #require(items(palette).first { $0.title == "Stage all" })
        #expect(stage.isEnabled)
        palette.close()
        shell.app.run(stage)
        await appWaitUntil { shell.app.model.hasStagedChanges && !shell.app.model.isMutating }

        shell.app.showCommandPalette()
        palette = try #require(shell.app.palette)
        let commit = try #require(items(palette).first { $0.title == "Commit staged" })
        #expect(commit.isEnabled)
        palette.close()
        shell.app.run(commit)
        #expect(shell.app.model.section == .changes)
    }

    @Test func aRepositoryOpensInItsTab() async throws {
        let repository = try repository()
        let other = try self.repository()
        let shell = await launched(repository)
        defer { shell.tearDown() }
        shell.defaults.set([other.url.path], forKey: Preference.recentRepositories.rawValue)
        shell.app.showPalette(scope: .repository)
        let palette = try #require(shell.app.palette)
        #expect(palette.state.scope == .repository)
        let item = try #require(
            items(palette).first { $0.action == .repository(other.url) || $0.id.hasSuffix(other.url.path) })
        palette.close()
        shell.app.run(item)
        await appWaitUntil { shell.app.tabsController?.count == 2 }
    }

    @Test func commandNStartsABranchNamedAfterWhatIsTyped() async throws {
        let repository = try repository()
        let shell = await launched(repository)
        defer { shell.tearDown() }
        shell.app.showCommandPalette()
        var palette = try #require(shell.app.palette)
        type("feature-x", palette)
        palette.newBranch()
        #expect(shell.alerts.fields.first?.stringValue == "feature-x")
        shell.alerts.answer(.alertSecondButtonReturn)
        shell.app.showCommandPalette()
        palette = try #require(shell.app.palette)
        type("two words", palette)
        palette.newBranch()
        #expect(shell.alerts.fields.first?.stringValue.isEmpty == true)
        shell.alerts.answer(.alertSecondButtonReturn)
        shell.app.model.isMutating = true
        shell.app.showCommandPalette()
        palette = try #require(shell.app.palette)
        #expect(items(palette).first { $0.kind == .branch && !$0.isCurrent }?.isEnabled != true)
        palette.newBranch()
        #expect(shell.recorder.beeps == 1)
        shell.app.model.isMutating = false
    }

    @Test func aWorkspaceOpensFromThePalette() async throws {
        let repository = try repository()
        let shell = await launched(repository)
        defer { shell.tearDown() }
        shell.app.newWorkspace()
        #expect(shell.alerts.last?.messageText == String(localized: "New workspace"))
        shell.alerts.fields.first?.stringValue = "Client"
        shell.alerts.answer()
        await appWaitUntil { shell.app.place.workspace.name == "Client" }
        shell.app.showCommandPalette()
        let palette = try #require(shell.app.palette)
        let first = try #require(items(palette).first { $0.action == .workspace(Workspace.firstID) })
        #expect(first.kind == .workspace && first.title == String(localized: "Default") && first.isEnabled)
        palette.close()
        shell.app.run(first)
        await appWaitUntil { shell.app.place.workspace.id == Workspace.firstID }
    }

    @Test func aSheetOrTheSetupGuideKeepsItAway() async throws {
        let repository = try repository()
        let shell = await launched(repository)
        defer { shell.tearDown() }
        let window = try #require(shell.app.mainWindow)
        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered,
            defer: true)
        sheet.isReleasedWhenClosed = false
        window.beginSheet(sheet) { _ in }
        shell.app.showCommandPalette()
        #expect(shell.app.palette == nil && shell.recorder.beeps == 1)
        window.endSheet(sheet)
        shell.app.showSetupGuide()
        shell.app.showCommandPalette()
        #expect(shell.app.palette == nil)
    }
}
