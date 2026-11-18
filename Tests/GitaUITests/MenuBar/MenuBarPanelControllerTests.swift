import AppKit
import GitaCore
import Testing

@testable import GitaUI

@MainActor
@Suite struct MenuBarPanelControllerTests {
    typealias MF = MenuBarFixtures

    /// Every request the panel makes of the app, in order.
    @MainActor final class Recorder {
        var calls: [String] = []
        var opened: [URL] = []
        var copied: [String] = []
        var sizes: [NSSize] = []

        var actions: MenuPanelActions {
            MenuPanelActions(
                openApp: { self.calls.append("openApp") }, refresh: { self.calls.append("refresh") },
                settings: { self.calls.append("settings") }, quit: { self.calls.append("quit") },
                openRepository: { self.calls.append("openRepository") },
                showRepository: { self.calls.append("show:" + $0.lastPathComponent) },
                showTab: { self.calls.append("tab:" + $0.lastPathComponent + "@" + $1) },
                push: { self.calls.append("push:" + $0.lastPathComponent) },
                reveal: { self.calls.append("reveal:" + $0.id) },
                openWorkspace: { self.calls.append("workspace:" + $0) },
                newWorkspace: { self.calls.append("newWorkspace") })
        }

        func controller() -> (MenuPanelController, NSWindow) {
            let controller = MenuPanelController(actions: actions)
            controller.openURL = { self.opened.append($0) }
            controller.copyText = { self.copied.append($0) }
            controller.onSizeChange = { self.sizes.append($0) }
            let window = UITestSupport.host(controller, size: NSSize(width: Theme.panelWidth, height: 400))
            return (controller, window)
        }
    }

    static func key(_ code: UInt16, _ characters: String = "", _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    private static let run = URL(string: "https://github.com/owner/app/actions/runs/1")!

    /// An agent waits and checks fail in "app"; an agent works and one idles; "app" and "site" are the front
    /// workspace's tabs, and a second workspace is closed.
    private func state() -> MenuPanelState {
        var app = MenuPanelState.Repository(root: MF.repository, name: "app", branch: "main", ahead: 2)
        app.preview = .init(url: URL(string: "https://app-git-main.vercel.app")!, state: .success)
        let site = MenuPanelState.Repository(root: MF.site, name: "site", branch: "main")
        let event = FeedEvent(
            id: "1", kind: .checksFailed, repository: MF.repository, repositoryName: "app", title: "Checks failed · CI",
            detail: "main", date: MF.now, url: Self.run, sessionID: nil)
        return MenuPanelState(
            repositories: [app, site],
            workspaces: [
                MF.workspace("front", title: "Gitā", repositories: [MF.repository, MF.site]),
                MF.workspace("closed", title: "Open source", presence: .closed, repositories: [MF.site]),
            ],
            attention: [
                .init(
                    id: "agent:n", kind: .agentWaiting(tool: .claudeCode, session: "n"), repository: MF.repository,
                    detail: "app", date: MF.now),
                .init(
                    id: "checks:app", kind: .checksFailed, repository: MF.repository, detail: "app · main · CI",
                    date: MF.now, url: Self.run),
            ],
            sessions: [
                MF.Session(id: "n", state: .needsInput).make(),
                MF.Session(id: "w", state: .working, tool: .codex).make(),
                MF.Session(id: "i", state: .idle).make(),
            ],
            feed: [event], problem: "GitHub · Sign in required · app", checkedAt: Date())
    }

    private func rowView(_ controller: MenuPanelController, _ id: String) -> PanelRowView? {
        controller.list.subviews.compactMap { $0 as? PanelRowView }.first { $0.row.id == id }
    }

    private func button(_ view: NSView, _ identifier: String) -> NSButton? {
        if let button = view as? NSButton, button.accessibilityIdentifier() == identifier { return button }
        for child in view.subviews { if let found = button(child, identifier) { return found } }
        return nil
    }

    // MARK: State

    @Test func showsTheInboxOfTheState() {
        let recorder = Recorder()
        let (controller, _) = recorder.controller()
        #expect(controller.list.rows.map(\.id) == ["calm"])
        #expect(controller.caption.stringValue == "NEEDS YOU")
        controller.update(state())
        controller.update(state())
        #expect(
            controller.list.rows.map(\.id) == [
                "attention:agent:n", "attention:checks:app", "section:agents", "agent:w", "idle",
                "section:workspaces", "workspace:front", "workspace:closed",
            ])
        #expect(controller.caption.stringValue == "NEEDS YOU  2")
        #expect(controller.problemLabel.stringValue == "GitHub · Sign in required · app")
        #expect(button(controller.view, "panel.refresh")?.toolTip?.hasPrefix("Refresh · Checked ") == true)
        #expect(button(controller.view, "panel.back")?.isHidden == true)
        #expect(controller.preferredContentSize.width == Theme.panelWidth)
        #expect(recorder.sizes.last == controller.preferredContentSize)
        UITestSupport.render(controller.view)

        var refreshing = state()
        refreshing.isRefreshing = true
        refreshing.problem = nil
        controller.update(refreshing)
        #expect(button(controller.view, "panel.refresh")?.toolTip == "Refreshing…")
        #expect(controller.problemLabel.stringValue.isEmpty)
        #expect(button(controller.view, "panel.refresh")?.isEnabled == false)
        button(controller.view, "panel.refresh")?.performClick(nil)
        #expect(recorder.calls.isEmpty)
    }

    @Test func refreshTextIsTimeTodayAndDateOtherwise() {
        var state = MenuPanelState()
        #expect(MenuPanelController.refreshText(state, now: MF.now) == "Refresh")
        state.checkedAt = MF.now.addingTimeInterval(-60)
        let today = MenuPanelController.refreshText(state, now: MF.now)
        state.checkedAt = MF.now.addingTimeInterval(-3 * 86_400)
        let earlier = MenuPanelController.refreshText(state, now: MF.now)
        #expect(today.hasPrefix("Refresh · Checked ") && earlier.hasPrefix("Refresh · Checked "))
        #expect(earlier.count > today.count)
        state.isRefreshing = true
        #expect(MenuPanelController.refreshText(state, now: MF.now) == "Refreshing…")
    }

    @Test func theCaptionCountsWhatNeedsYou() {
        #expect(MenuPanelController.caption(.inbox, needing: 0).string == "NEEDS YOU")
        #expect(MenuPanelController.caption(.inbox, needing: 3).string == "NEEDS YOU  3")
        #expect(MenuPanelController.caption(.activity, needing: 3).string == "ACTIVITY")
        let waiting = MenuPanelController.caption(.inbox, needing: 1)
        #expect(waiting.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == Theme.needsInputText)
        let calm = MenuPanelController.caption(.inbox, needing: 0)
        #expect(calm.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == Theme.secondaryText)
    }

    @Test func activityShowsTheFeedAndBackOrEscapeReturns() throws {
        let recorder = Recorder()
        let (controller, _) = recorder.controller()
        controller.update(state())
        controller.list.select(id: "agent:w")
        let activity = try #require(button(controller.view, "panel.activity"))
        activity.performClick(nil)
        #expect(controller.page == .activity)
        #expect(controller.list.rows.map(\.id) == ["feed:1"])
        #expect(controller.list.selectedID == nil)
        #expect(controller.caption.stringValue == "ACTIVITY")
        #expect(activity.isHidden)
        let back = try #require(button(controller.view, "panel.back"))
        #expect(!back.isHidden)
        UITestSupport.render(controller.view)
        back.performClick(nil)
        #expect(controller.page == .inbox)
        #expect(!activity.isHidden && back.isHidden)

        // Esc goes back from Activity; on the inbox it is left to close the panel.
        controller.show(.activity)
        controller.show(.activity)
        #expect(controller.back())
        #expect(controller.page == .inbox)
        #expect(!controller.back())
    }

    @Test func commandShortcutsReachTheApp() {
        let recorder = Recorder()
        let (controller, _) = recorder.controller()
        controller.update(state())
        for (code, key) in [(UInt16(43), ","), (12, "q"), (15, "r"), (31, "o"), (45, "n"), (18, "1"), (19, "2")] {
            #expect(controller.handleKeyEquivalent(Self.key(code, key, .command)))
        }
        // There is no third workspace, and ⌘0 is none.
        #expect(!controller.handleKeyEquivalent(Self.key(20, "3", .command)))
        #expect(!controller.handleKeyEquivalent(Self.key(29, "0", .command)))
        #expect(!controller.handleKeyEquivalent(Self.key(0, "a", .command)))
        #expect(!controller.handleKeyEquivalent(Self.key(12, "q")))
        #expect(
            recorder.calls == [
                "settings", "quit", "refresh", "openApp", "newWorkspace", "workspace:front", "workspace:closed",
            ])
        // The root view hands ⌘ shortcuts to its controller.
        #expect(controller.view.performKeyEquivalent(with: Self.key(31, "o", .command)))
        #expect(!controller.view.performKeyEquivalent(with: Self.key(0, "a", .command)))
        #expect(recorder.calls.last == "openApp")
    }

    @Test func headerAndFooterButtonsAndTheMoreMenu() throws {
        let recorder = Recorder()
        let (controller, _) = recorder.controller()
        try #require(button(controller.view, "panel.open")).performClick(nil)
        try #require(button(controller.view, "panel.refresh")).performClick(nil)
        let menu = controller.moreMenu()
        #expect(menu.items.map(\.keyEquivalent) == [",", "", "q"])
        for item in menu.items where !item.isSeparatorItem {
            NSApp.sendAction(try #require(item.action), to: item.target, from: item)
        }
        try #require(button(controller.view, "panel.openRepository")).performClick(nil)
        try #require(button(controller.view, "panel.newWorkspace")).performClick(nil)
        #expect(recorder.calls == ["openApp", "refresh", "settings", "quit", "openRepository", "newWorkspace"])
    }

    // MARK: Rows

    @Test func keyboardSelectsAndActivatesRows() {
        let recorder = Recorder()
        let (controller, _) = recorder.controller()
        controller.update(state())
        controller.makeListFirstResponder()
        let list = controller.list
        list.keyDown(with: Self.key(125))
        #expect(list.selectedID == "attention:agent:n")
        #expect(rowView(controller, "attention:agent:n")?.isSelected == true)
        list.keyDown(with: Self.key(36, "\r"))
        #expect(recorder.calls == ["reveal:n"])
        // ⌘C copies a link only where the row has one.
        list.keyDown(with: Self.key(8, "c", .command))
        #expect(recorder.copied.isEmpty)
        list.keyDown(with: Self.key(125))
        list.keyDown(with: Self.key(8, "c", .command))
        #expect(recorder.copied == [Self.run.absoluteString])
        list.keyDown(with: Self.key(49, " "))
        #expect(recorder.opened == [Self.run])
        list.keyDown(with: Self.key(126))
        #expect(list.selectedID == "attention:agent:n")
        list.keyDown(with: Self.key(0, "a"))
        controller.show(.activity)
        #expect(list.selectedID == nil)
        list.keyDown(with: Self.key(125))
        list.keyDown(with: Self.key(49, " "))
        #expect(recorder.opened == [Self.run, Self.run])
    }

    @Test func arrowsMoveThroughAWorkspacesPills() throws {
        let recorder = Recorder()
        let (controller, _) = recorder.controller()
        controller.update(state())
        let list = controller.list
        list.select(id: "workspace:front")
        let card = try #require(rowView(controller, "workspace:front"))
        list.keyDown(with: Self.key(36, "\r"))
        #expect(recorder.calls == ["workspace:front"])
        list.keyDown(with: Self.key(124))
        #expect(list.selectedPill == 0)
        #expect(card.pillsView?.buttons.map(\.isChosen) == [true, false])
        UITestSupport.render(card)
        list.keyDown(with: Self.key(124))
        list.keyDown(with: Self.key(124))
        #expect(list.selectedPill == 1)
        list.keyDown(with: Self.key(76, "\u{3}"))
        #expect(recorder.calls.last == "tab:site@front")
        // The chosen pill survives a refresh of the same rows, and ← leads back to the card itself.
        var next = state()
        next.checkedAt = MF.now
        controller.update(next)
        #expect(rowView(controller, "workspace:front")?.selectedPill == 1)
        list.keyDown(with: Self.key(123))
        list.keyDown(with: Self.key(123))
        #expect(list.selectedPill == nil && list.selectedID == "workspace:front")
        #expect(card.pillsView?.buttons.map(\.isChosen) == [false, false])
        // Moving to another row lets go of the pill; a closed workspace's labels are never chosen.
        list.keyDown(with: Self.key(124))
        list.keyDown(with: Self.key(125))
        #expect(list.selectedID == "workspace:closed" && list.selectedPill == nil)
        list.keyDown(with: Self.key(124))
        #expect(list.selectedPill == nil)
        list.keyDown(with: Self.key(36, "\r"))
        #expect(recorder.calls.last == "workspace:closed")
    }

    @Test func arrowsOpenAndCloseTheIdleSummary() {
        let recorder = Recorder()
        let (controller, _) = recorder.controller()
        controller.update(state())
        let list = controller.list
        list.select(id: "idle")
        list.keyDown(with: Self.key(124))
        #expect(list.rows.map(\.id).contains("agent:i"))
        #expect(rowView(controller, "idle")?.row.disclosure == .expanded)
        list.keyDown(with: Self.key(124))
        #expect(list.rows.map(\.id).contains("agent:i"))
        list.keyDown(with: Self.key(123))
        #expect(!list.rows.map(\.id).contains("agent:i"))
        list.select(id: "agent:w")
        list.keyDown(with: Self.key(76, "\u{3}"))
        #expect(recorder.calls == ["reveal:w"])
    }

    @Test func clicksPressesChipsAndPillsPerformTheirActions() throws {
        let recorder = Recorder()
        let (controller, window) = recorder.controller()
        controller.update(state())
        let card = try #require(rowView(controller, "attention:checks:app"))
        #expect(card.accessibilityPerformPress())
        #expect(controller.list.selectedID == card.row.id)
        try #require(card.chipViews.first).performClick(nil)
        #expect(recorder.opened == [Self.run, Self.run])
        let front = try #require(rowView(controller, "workspace:front"))
        let pills = try #require(front.pillsView).buttons
        pills[0].performClick(nil)
        let menu = try #require(pills[0].menu(for: Self.mouse(.rightMouseDown, at: .zero, in: window)))
        #expect(menu.items.map(\.title) == ["Show in Gitā", "Push 2", "Open Preview", "Copy Path"])
        for item in menu.items { NSApp.sendAction(try #require(item.action), to: item.target, from: item) }
        try #require(rowView(controller, "workspace:closed")?.chipViews.first).performClick(nil)
        #expect(recorder.calls == ["tab:app@front", "tab:app@front", "push:app", "workspace:closed"])
        #expect(recorder.opened.last == URL(string: "https://app-git-main.vercel.app"))
        #expect(recorder.copied == [MF.repository.path])

        // A press that ends outside the row does nothing.
        let inside = front.convert(NSPoint(x: 100, y: 12), to: nil)
        front.mouseDown(with: Self.mouse(.leftMouseDown, at: inside, in: window))
        #expect(front.pressed)
        UITestSupport.render(front)
        front.mouseUp(with: Self.mouse(.leftMouseUp, at: NSPoint(x: -500, y: -500), in: window))
        #expect(!front.pressed)
        #expect(recorder.calls.count == 4)
        front.mouseDown(with: Self.mouse(.leftMouseDown, at: inside, in: window))
        front.mouseUp(with: Self.mouse(.leftMouseUp, at: inside, in: window))
        #expect(recorder.calls.last == "workspace:front")
        front.mouseUp(with: Self.mouse(.leftMouseUp, at: inside, in: window))
        #expect(recorder.calls.count == 5)
    }

    @Test func rowActionsRouteToTheApp() {
        let recorder = Recorder()
        let (controller, _) = recorder.controller()
        controller.update(state())
        let perform = controller.list.onAction
        perform?(.reveal("w"))
        perform?(.reveal("unknown"))
        perform?(.openRepository)
        perform?(.showRepository(MF.site))
        perform?(.newWorkspace)
        perform?(.openURL(URL(string: "http://insecure.example.com")!))
        perform?(.openURL(URL(string: "https://example.com")!))
        perform?(.copy("text"))
        perform?(.toggle("idle"))
        #expect(recorder.calls == ["reveal:w", "openRepository", "show:site", "newWorkspace"])
        #expect(recorder.opened == [URL(string: "https://example.com")!])
        #expect(recorder.copied == ["text"])
        #expect(controller.list.rows.map(\.id).contains("agent:i"))
        perform?(.showActivity)
        #expect(controller.page == .activity)
    }

    @Test func hoverMovesBetweenRowsAndShowsTheHoverChip() throws {
        let recorder = Recorder()
        let (controller, window) = recorder.controller()
        var state = state()
        state.sessions.append(MF.Session(id: "d", state: .done).make())
        controller.update(state)
        let first = try #require(rowView(controller, "agent:w"))
        let second = try #require(rowView(controller, "agent:d"))
        let event = Self.mouse(.mouseMoved, at: .zero, in: window)
        first.mouseEntered(with: event)
        #expect(first.isHovered)
        #expect(first.hoverChipView?.isHidden == false)
        UITestSupport.render(first)
        second.mouseEntered(with: event)
        #expect(!first.isHovered && second.isHovered)
        first.mouseExited(with: event)
        #expect(second.isHovered)
        second.mouseExited(with: event)
        #expect(!second.isHovered)
        #expect(second.hoverChipView?.isHidden == true)
        second.updateTrackingAreas()
        #expect(second.trackingAreas.count == 1)
        // A card shows a hairline under the pointer.
        let card = try #require(rowView(controller, "workspace:closed"))
        card.mouseEntered(with: event)
        UITestSupport.render(card)
        card.mouseExited(with: event)
    }

    static func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
}
