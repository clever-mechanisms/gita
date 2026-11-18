import AppKit
import GitaCore
import Testing

@testable import GitaUI

@MainActor
@Suite("Palette items")
struct PaletteItemsTests {
    private static func menu() -> NSMenu {
        let main = NSMenu()
        let repository = NSMenuItem(title: "Repository", action: nil, keyEquivalent: "")
        repository.submenu = NSMenu(title: "Repository")
        main.addItem(repository)
        let push = NSMenuItem(title: "Push…", action: #selector(RepositoryCommandResponder.push), keyEquivalent: "P")
        push.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: nil)
        let pull = NSMenuItem(title: "Pull", action: #selector(RepositoryCommandResponder.pull), keyEquivalent: "l")
        pull.keyEquivalentModifierMask = [.command, .option]
        let hidden = NSMenuItem(
            title: "Hidden", action: #selector(RepositoryCommandResponder.fetch), keyEquivalent: "")
        hidden.isHidden = true
        let copy = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        let heading = NSMenuItem(title: "Heading", action: nil, keyEquivalent: "")
        for item in [push, .separator(), pull, hidden, copy, heading] { repository.submenu?.addItem(item) }
        return main
    }

    @Test func everyMenuItemThatRunsSomethingIsACommand() throws {
        let menu = Self.menu()
        let commands = PaletteItems.commands(
            in: menu, aliases: [#selector(RepositoryCommandResponder.push): ["upload"]]
        ) { $0.action != #selector(RepositoryCommandResponder.pull) }
        #expect(commands.map(\.title) == ["Push", "Pull"])
        let push = try #require(commands.first)
        #expect(push.detail == "Repository" && push.trailing == "⇧⌘P" && push.keywords == ["upload"])
        #expect(push.kind == .command && push.isEnabled)
        #expect(push.id == "command.push.0.Push…")
        guard case .image = push.icon, case .menu(let item) = push.action else {
            Issue.record("the menu item's image and action")
            return
        }
        #expect(item.title == "Push…")
        #expect(commands[1].trailing == "⌥⌘L" && !commands[1].isEnabled && commands[1].icon == .symbol("command"))
        let skipped = PaletteItems.commands(
            in: menu, skipping: [#selector(RepositoryCommandResponder.push)]
        ) { _ in true }
        #expect(skipped.map(\.title) == ["Pull"])
        #expect(PaletteItems.shortcut(of: NSMenuItem()).isEmpty)
        #expect(PaletteItems.commandTitle("Settings…") == "Settings")
    }

    @Test func systemMenuExtrasAreNotCommands() {
        let edit = NSMenu(title: "Edit")
        let autofill = NSMenuItem(title: "AutoFill", action: nil, keyEquivalent: "")
        autofill.submenu = NSMenu(title: "AutoFill")
        autofill.submenu?.addItem(
            NSMenuItem(title: "Passwords…", action: Selector(("orderFrontPasswordManager:")), keyEquivalent: ""))
        autofill.submenu?.addItem(
            NSMenuItem(title: "Credit Cards", action: Selector(("orderFrontCreditCardAutoFill:")), keyEquivalent: ""))
        edit.addItem(autofill)
        edit.addItem(
            NSMenuItem(
                title: "Emoji & Symbols", action: #selector(NSApplication.orderFrontCharacterPalette(_:)),
                keyEquivalent: ""))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(
            NSMenuItem(title: "Find in History", action: #selector(AppDelegate.findInHistory), keyEquivalent: "f"))
        edit.addItem(
            NSMenuItem(title: "Hide Gitā", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        edit.addItem(
            NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        let sidebar = MenuAction("Sidebar") {}
        edit.addItem(sidebar)
        let commands = PaletteItems.commands(in: edit) { _ in true }
        #expect(commands.map(\.title) == ["Find in History", "Hide Gitā", "Minimize", "Sidebar"])
        #expect(
            !commands.contains {
                ["Passwords", "Credit Cards", "Emoji & Symbols", "Copy", "AutoFill"].contains($0.title)
            })
    }

    @Test func settingsPanesOpenDirectly() {
        let settings = PaletteItems.settings
        #expect(settings.count == SettingsPane.allCases.count)
        #expect(settings.allSatisfy { $0.kind == .command && $0.keywords.contains("preferences") })
        #expect(settings.first?.action == .settings(.general))
    }

    @Test func branchesSayWhereTheyAreAndWhetherTheyCanBeCheckedOut() {
        let date = Date(timeIntervalSinceNow: -3600 * 30)
        let entries = [
            BranchPaletteEntry(name: "main", fullName: "refs/heads/main", isCurrent: true),
            BranchPaletteEntry(name: "wip", fullName: "refs/heads/wip", worktree: "/r-wip"),
            BranchPaletteEntry(name: "origin/release", fullName: "refs/remotes/origin/release", isRemote: true),
            BranchPaletteEntry(name: "old", fullName: "refs/heads/old", date: date),
        ]
        let blocked = PaletteItems.branches(entries, canSwitch: false)
        #expect(blocked.map(\.isEnabled) == [true, true, false, false])
        #expect(blocked.map(\.isCurrent) == [true, false, false, false])
        #expect(
            blocked.map(\.icon) == [
                .symbol("checkmark"), .symbol(Deck.worktreeSymbol), .symbol("cloud"), .symbol("arrow.triangle.branch"),
            ])
        #expect(blocked[0].detail == "current" && blocked[1].detail == "in r-wip" && blocked[2].detail.isEmpty)
        #expect(blocked[3].trailing == DeckFormat.relative(date) && blocked[0].trailing.isEmpty)
        #expect(blocked[1].id == "branch.refs/heads/wip" && blocked[1].action == .branch(entries[1]))
        #expect(PaletteItems.branches(entries, canSwitch: true).allSatisfy { $0.isEnabled })
    }

    @Test func commitsAreFoundBySubjectAuthorAndHash() throws {
        let commit = GitCommit(
            id: "0123456789abcdef", parents: [], subject: "Fix login", author: "Ada",
            date: Date(timeIntervalSince1970: 0))
        let item = try #require(PaletteItems.commits([commit]).first)
        #expect(item.title == "Fix login" && item.detail == "0123456 · Ada" && item.keywords == [commit.id])
        #expect(item.action == .commit(commit.id) && item.kind == .commit)
        #expect(PaletteEntry(item).result(for: PaletteText.tokens("0123456789ab ada")) != nil)
    }

    @Test func providerSignalsGoToTheirKindWhileTheirPageIsOn() {
        let pull = ProviderItem(
            id: "pr", provider: .github, category: "PR", title: "Add palette", state: .running, branch: "palette",
            kind: .pullRequest,
            pullRequest: PullRequestSummary(number: 7, lifecycle: .open, isDraft: false))
        let run = ProviderItem(
            id: "run", provider: .github, category: "CI", title: "CI", state: .success, detail: "passed",
            date: Date(timeIntervalSince1970: 0), kind: .workflowRun)
        let deployment = ProviderItem(
            id: "dep", provider: .vercel, category: "Deployment", title: "gita", state: .success, kind: .deployment)
        let agent = ProviderItem(
            id: "agent", provider: .github, category: "", title: "Agent", state: .neutral, kind: .agent)
        let signals = [pull, run, deployment, agent]
        let all = PaletteItems.provider(signals) { _ in true }
        #expect(all.map(\.kind) == [.pullRequest, .workflow, .deployment])
        #expect(all[0].detail == "#7 · palette" && all[0].id == "pullRequest.pr" && all[0].action == .provider(pull))
        #expect(all[1].detail == "passed" && !all[1].trailing.isEmpty && all[2].detail.isEmpty)
        #expect(all[0].icon == .symbol(Section.pullRequests.symbol))
        let withoutVercel = PaletteItems.provider(signals) { $0 != .deployments }
        #expect(withoutVercel.map(\.kind) == [.pullRequest, .workflow])
    }

    @Test func repositoriesAreTheOpenTabsThenTheRecentOnesEachOnce() {
        let open = [URL(fileURLWithPath: "/Users/me/code/gita"), URL(fileURLWithPath: "/srv/app")]
        let items = PaletteItems.repositories(
            open: open, selected: open[0], recent: ["/srv/app", "/Users/me/old"], canOpen: false, home: "/Users/me")
        #expect(items.map(\.title) == ["gita", "app", "old"])
        #expect(items.map(\.detail) == ["~/code", "/srv", "~"])
        #expect(items.map(\.isCurrent) == [true, false, false] && items.allSatisfy { !$0.isEnabled })
        #expect(items[2].action == .repository(URL(fileURLWithPath: "/Users/me/old", isDirectory: true)))
        #expect(PaletteItems.repositories(open: [], selected: nil, recent: ["/a"]).first?.isEnabled == true)
    }

    @Test func eachKindHasATitleAndLimits() {
        let symbols = PaletteKind.allCases.map(\.symbol)
        for kind in PaletteKind.allCases {
            #expect(!kind.title.isEmpty)
            #expect(!kind.symbol.isEmpty)
            #expect(kind.sharedLimit(hasQuery: true) > 0)
        }
        #expect(Set(symbols).count == symbols.count)
        #expect(PaletteKind.commit.sharedLimit(hasQuery: false) == 0)
        #expect(PaletteKind.branch.symbol == "arrow.triangle.branch")
        #expect(PaletteKind.pullRequest.symbol == Section.pullRequests.symbol)
        #expect(PaletteKind.workspace.symbol == Deck.workspaceSymbol)
        #expect(Deck.workspaceSymbol != Deck.worktreeSymbol)
        #expect(PaletteKind.workspace.title == String(localized: "Workspaces"))
    }

    @Test func workspacesAreTheirOwnKindAndStayOutOfCommands() {
        var list = WorkspaceList()
        #expect(list.add(named: "Client") != nil)
        let content = WorkspaceMenu.Content(
            list: list, shown: Workspace.firstID, windowed: [Workspace.firstID], canChange: false)
        let menu = NSMenu()
        WorkspaceMenu.items(
            content,
            actions: WorkspaceMenu.Actions(open: { _ in }, new: {}, rename: {}, delete: {})
        ).forEach(menu.addItem)
        let commands = PaletteItems.commands(in: menu) { _ in true }
        #expect(commands.map(\.title).contains { $0.hasPrefix("New Workspace") })
        #expect(!commands.contains { $0.title == String(localized: "Default") || $0.title == "Client" })
        let items = PaletteItems.workspaces(
            list.workspaces, selected: Workspace.firstID, windowed: [Workspace.firstID], canSwitch: false)
        #expect(items.map(\.title) == [String(localized: "Default"), "Client"])
        #expect(items.map(\.isCurrent) == [true, false])
        #expect(items.map(\.isEnabled) == [true, false])
        #expect(items[0].kind == .workspace && items[0].action == .workspace(Workspace.firstID))
        #expect(items[1].icon == .symbol(Deck.workspaceSymbol))
        #expect(PaletteItems.workspaces(list.workspaces, selected: Workspace.firstID, canSwitch: true)[1].isEnabled)
    }
}
