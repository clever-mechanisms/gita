import AppKit
import Foundation
import Testing

@testable import GitaCore
@testable import GitaUI

@MainActor
@Suite("Keyboard pane focus, terminal height memory, and Activity copy command")
struct PaneFocusAndPolishTests {
    @Test func paneFocusShortcutsAreDistinctRebindableAndFocusPanes() throws {
        UITestSupport.bootstrap()
        let sandbox = try SetupSandbox()
        let model = AppModel(defaults: sandbox.defaults)
        let controller = RepositoryViewController(model: model)
        let window = UITestSupport.host(controller, size: NSSize(width: 1_100, height: 800))
        defer {
            controller.detach()
            window.close()
        }

        // Defaults are distinct and focus commands rebind cleanly.
        let custom = KeyShortcut("9", [.control, .option])
        ShortcutStore.set(custom, for: .focusDiff, sandbox.defaults)
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.control, .option], timestamp: 0, windowNumber: 0,
                context: nil, characters: "9", charactersIgnoringModifiers: "9", isARepeat: false, keyCode: 25))
        #expect(ShortcutStore.focusCommand(using: event, sandbox.defaults) == .focusDiff)

        controller.focusPane(.sidebar)
        #expect(controller.focusedPane == .sidebar)
        #expect(window.firstResponder === controller.sidebarView.repositoryPane.list.table)

        controller.focusPane(.history)
        #expect(controller.focusedPane == .history)
        #expect(window.firstResponder === controller.historyTable.table)

        controller.focusPane(.files)
        #expect(controller.focusedPane == .files)

        controller.focusPane(.diff)
        #expect(controller.focusedPane == .diff)
        #expect(window.firstResponder === controller.codePane.diffView.table)

        controller.cyclePaneFocus()
        #expect(controller.focusedPane == .sidebar)

        controller.cyclePaneFocus(forward: false)
        #expect(controller.focusedPane == .diff)

        // Pane focus makes hidden sections/details visible automatically.
        controller.model.section = .pullRequests
        controller.focusPane(.history)
        #expect(controller.model.section == .history)
        controller.selectDetailTab(.commit)
        controller.focusPane(.files)
        #expect(controller.detailTab == .changes)
        controller.toggleSidebar()
        controller.focusPane(.sidebar)
        #expect(!controller.sidebarView.isHidden)

        // Ctrl+Opt+Tab cycles focus via the key-equivalent handler.
        let tabCycle = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.control, .option], timestamp: 0, windowNumber: 0,
                context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
        #expect(controller.content.subviews.contains { $0.performKeyEquivalent(with: tabCycle) })
        #expect(controller.focusedPane == .history)
    }

    @Test func appDelegateInstallsFocusMenuItems() throws {
        let harness = AppShellHarness()
        let delegate = harness.app
        let mainMenu = NSMenu()
        let viewRoot = NSMenuItem(title: String(localized: "View"), action: nil, keyEquivalent: "")
        viewRoot.submenu = NSMenu(title: String(localized: "View"))
        mainMenu.addItem(viewRoot)
        delegate.installPaneFocusMenuItemsIfNeeded(in: mainMenu)
        let identifiers = Set(viewRoot.submenu?.items.compactMap(\.identifier) ?? [])
        #expect(identifiers.contains(ShortcutCommand.focusSidebar.menuIdentifier))
        #expect(identifiers.contains(ShortcutCommand.focusDiff.menuIdentifier))
        #expect(identifiers.contains(ShortcutCommand.cyclePaneFocus.menuIdentifier))
    }

    @Test func terminalPanelRemembersHeightPerTerminalAndRepositoryTab() throws {
        UITestSupport.bootstrap()
        let sandbox = try SetupSandbox()
        let panel = TerminalPanelView()
        panel.defaults = sandbox.defaults
        var harnesses: [SessionHarness] = []
        panel.makeTerminal = { folder, launch in
            let harness = SessionHarness(launch: launch, folder: folder)
            harnesses.append(harness)
            return TerminalView(session: harness.session, page: nil)
        }
        var activeRepo = URL(fileURLWithPath: "/tmp/repo-one")
        panel.currentDirectory = { activeRepo }
        let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: 900, height: 1_000))
        split.isVertical = false
        split.addArrangedSubview(NSView())
        split.addArrangedSubview(panel)
        split.delegate = panel

        let first = panel.open(activeRepo)
        panel.frame.size.height = 420
        let dragged = Notification(
            name: NSSplitView.didResizeSubviewsNotification, object: split, userInfo: ["NSSplitViewDividerIndex": 0])
        panel.splitViewDidResizeSubviews(dragged)
        #expect(panel.rememberedShare(terminalID: first.id) == 0.42)

        let second = panel.open(activeRepo)
        panel.frame.size.height = 240
        panel.splitViewDidResizeSubviews(dragged)
        #expect(panel.rememberedShare(terminalID: second.id) == 0.24)

        panel.select(first.id)
        #expect(abs(panel.rememberedShare() - 0.42) < 0.001)

        // Switching repository context remembers per-tab share.
        activeRepo = URL(fileURLWithPath: "/tmp/repo-two")
        let other = panel.open(activeRepo)
        panel.frame.size.height = 350
        panel.splitViewDidResizeSubviews(dragged)
        #expect(
            abs(panel.rememberedShare(forKey: activeRepo.standardizedFileURL.path, terminalID: other.id) - 0.35) < 0.001
        )
    }

    @Test func activityWindowFormatsShellQuotedCommandsAndCopiesForFailedRows() throws {
        let quoted = ActivityCommandFormatter.shellQuoted(["git", "-C", "/tmp/my repo", "commit", "-m", "it's ok", ""])
        #expect(quoted == "git -C '/tmp/my repo' commit -m 'it'\\''s ok' ''")

        let success = ActivityEntry(ActivityEvent(title: "Fetch", detail: "Completed", failed: false))
        #expect(ActivityCommandFormatter.command(for: success) == nil)

        let embedded = ActivityEntry(
            ActivityEvent(title: "Fetch", detail: "Command: git fetch --prune origin\nPermission denied", failed: true))
        #expect(ActivityCommandFormatter.command(for: embedded) == "git fetch --prune origin")

        let pushFailure = ActivityEntry(ActivityEvent(title: "Push", detail: "rejected", failed: true))
        #expect(ActivityCommandFormatter.command(for: pushFailure) == "git push")
        let githubFailure = ActivityEntry(ActivityEvent(title: "GitHub: Pull requests", detail: "auth", failed: true))
        #expect(ActivityCommandFormatter.command(for: githubFailure) == "gh pr list")
        let vercelFailure = ActivityEntry(ActivityEvent(title: "Vercel: Deployments", detail: "403", failed: true))
        #expect(ActivityCommandFormatter.command(for: vercelFailure) == "vercel ls")
        let appFailure = ActivityEntry(ActivityEvent(title: "Open result failed", detail: "oops", failed: true))
        #expect(ActivityCommandFormatter.command(for: appFailure) == nil)
        let recorded = ActivityCommandFormatter.command(
            for: pushFailure, recordedArguments: ["git", "push", "origin", "main"])
        #expect(recorded == "git push origin main")

        let harness = try WindowsActivityHarness()
        var copied: [String] = []
        harness.controller.copyToPasteboard = { copied.append($0) }
        harness.model.log("Fetch", "fatal: could not read from remote", failed: true)
        harness.model.log("Commit", "Completed", failed: false)
        _ = harness.window

        let table = harness.table
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        let copyButton = try #require(
            SetupTestSupport.views(PartsButton.self, in: harness.content).first {
                $0.accessibilityIdentifier() == "activity.copyCommand"
            })
        #expect(!copyButton.isHidden)
        copyButton.onClick?()
        #expect(copied.last == "git fetch --prune --all")

        let contextMenu = NSMenu()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        harness.controller.menuNeedsUpdate(contextMenu)
        #expect(contextMenu.items.isEmpty, "succeeded rows offer no Copy command menu item")

        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        harness.controller.menuNeedsUpdate(contextMenu)
        #expect(contextMenu.items.first?.title == String(localized: "Copy command"))
    }
}
