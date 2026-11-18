import AppKit
import GitaCore
import Testing

@testable import GitaUI

/// Mouse events for views that are not on screen.
@MainActor
enum TabsEvents {
    static func mouse(
        _ type: NSEvent.EventType, at point: NSPoint = .zero, in window: NSWindow? = nil,
        flags: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try #require(
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: flags, timestamp: 0,
                windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    static func other(button: Int) throws -> NSEvent {
        let mouseButton = try #require(CGMouseButton(rawValue: UInt32(button)))
        let cgEvent = try #require(
            CGEvent(
                mouseEventSource: nil, mouseType: .otherMouseUp, mouseCursorPosition: .zero,
                mouseButton: mouseButton))
        return try #require(NSEvent(cgEvent: cgEvent))
    }
}

@MainActor
@Suite("Tabs: tab view")
struct TabsTabViewTests {
    private func view() -> RepositoryTabView {
        UITestSupport.bootstrap()
        let view = RepositoryTabView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        view.layoutSubtreeIfNeeded()
        return view
    }

    @Test func updateShowsTheStateOnce() throws {
        let view = view()
        let state = RepositoryTabState(
            name: "app", branch: "main", path: "/x/app", agent: .needsInput, tool: .codex, selected: true,
            color: .blue, shortcut: 1)
        view.update(state)
        #expect(view.shown == state)
        #expect(view.toolTip == state.toolTip)
        #expect(view.accessibilityLabel() == state.accessibilityLabel)
        #expect(view.accessibilityValue() as? String == "selected")
        #expect(view.accessibilityCustomActions()?.first?.name == "Close app")
        view.update(state)
        var busy = state
        busy.busy = true
        busy.selected = false
        busy.agent = nil
        view.update(busy)
        #expect(view.accessibilityCustomActions()?.isEmpty == true)
        #expect(view.accessibilityValue() == nil)
    }

    @Test func drawsEveryLook() throws {
        let view = view()
        UITestSupport.render(view)
        for (selected, color) in [(true, TabColor?.some(.red)), (false, .green), (false, nil)] {
            view.update(RepositoryTabState(name: "app", selected: selected, color: color))
            UITestSupport.render(view)
            view.mouseEntered(with: try TabsEvents.mouse(.mouseMoved))
            UITestSupport.render(view)
            view.mouseExited(with: try TabsEvents.mouse(.mouseMoved))
        }
        for name in [NSAppearance.Name.darkAqua, .aqua] {
            view.appearance = NSAppearance(named: name)
            view.viewDidChangeEffectiveAppearance()
            UITestSupport.render(view)
        }
        view.updateTrackingAreas()
        #expect(view.trackingAreas.count == 1)
    }

    @Test func pressesSelectTrackAndClose() throws {
        let view = view()
        var log: [String] = []
        view.onSelect = { log.append("select") }
        view.onClose = { log.append("close") }
        view.onTrack = { _ in
            log.append("track")
            return false
        }
        view.menuProvider = { nil }
        view.mouseDown(with: try TabsEvents.mouse(.leftMouseDown))
        view.mouseDown(with: try TabsEvents.mouse(.leftMouseDown, flags: .control))
        view.otherMouseUp(with: try TabsEvents.other(button: 2))
        view.otherMouseUp(with: try TabsEvents.other(button: 3))
        #expect(view.accessibilityPerformPress())
        view.update(RepositoryTabState(name: "app"))
        let action = try #require(view.accessibilityCustomActions()?.first)
        #expect(action.handler?() == true)
        #expect(log == ["select", "track", "select", "track", "close", "select", "close"])
        #expect(view.menu(for: try TabsEvents.mouse(.rightMouseDown)) == nil)
        view.menuProvider = { NSMenu(title: "Tab") }
        #expect(view.menu(for: try TabsEvents.mouse(.rightMouseDown))?.title == "Tab")
    }
}

@MainActor
@Suite("Tabs: group chip")
struct TabsChipTests {
    private func chip() -> TabGroupChipView {
        UITestSupport.bootstrap()
        return TabGroupChipView(frame: NSRect(x: 0, y: 0, width: 120, height: 20))
    }
    private let tallies = [
        AgentTally(tool: .claudeCode, state: .working, count: 3), AgentTally(tool: .codex, state: .idle, count: 1),
    ]

    @Test func namedOpenGroupShowsItsName() throws {
        let chip = chip()
        let group = TabGroup(id: UUID(), name: "Work", color: .green)
        chip.update(group, count: 2, agents: tallies)
        #expect(chip.accessibilityLabel() == "Group Work, 2 tabs")
        #expect(chip.accessibilityValue() as? String == "Expanded")
        #expect(chip.toolTip == "Work\nClick to collapse")
        #expect(chip.preferredWidth > 26)
        chip.update(group, count: 2, agents: tallies)
        chip.layout()
        UITestSupport.render(chip)
    }

    @Test func collapsedGroupCountsTabsAndAgents() throws {
        let chip = chip()
        let group = TabGroup(id: UUID(), name: "Work", color: .green, collapsed: true)
        chip.update(group, count: 4, agents: [])
        let plain = chip.preferredWidth
        chip.update(group, count: 4, agents: tallies)
        #expect(chip.preferredWidth > plain)
        #expect(chip.accessibilityValue() as? String == "Collapsed")
        let label = chip.accessibilityLabel() ?? ""
        #expect(label.hasPrefix("Group Work, 4 tabs, Claude Code · "))
        #expect(label.contains("3 agents"))
        #expect(chip.toolTip?.hasSuffix("Click to show its tabs") == true)
        chip.setFrameSize(NSSize(width: 160, height: 20))
        chip.refreshFont()
        UITestSupport.render(chip)
        // Fewer kinds of agent hide the extra marks.
        chip.update(group, count: 4, agents: [tallies[1]])
        chip.layout()
        UITestSupport.render(chip)
        chip.mouseEntered(with: try TabsEvents.mouse(.mouseMoved))
        UITestSupport.render(chip)
        chip.mouseExited(with: try TabsEvents.mouse(.mouseMoved))
    }

    @Test func unnamedGroupsAreDotsOrCounts() throws {
        let chip = chip()
        UITestSupport.render(chip)
        chip.update(TabGroup(id: UUID(), name: "", color: .pink), count: 1, agents: [])
        #expect(chip.preferredWidth == 26)
        #expect(chip.toolTip == "Click to collapse")
        UITestSupport.render(chip)
        chip.update(TabGroup(id: UUID(), name: "", color: .pink, collapsed: true), count: 3, agents: [])
        #expect(chip.preferredWidth > 26)
        chip.appearance = NSAppearance(named: .darkAqua)
        chip.viewDidChangeEffectiveAppearance()
        chip.updateTrackingAreas()
        UITestSupport.render(chip)
    }

    @Test func clicksToggleUnlessTheyDrag() throws {
        let chip = chip()
        var toggles = 0
        var dragged = false
        chip.onToggle = { toggles += 1 }
        chip.onTrack = { _ in dragged }
        chip.menuProvider = { nil }
        chip.mouseDown(with: try TabsEvents.mouse(.leftMouseDown))
        chip.mouseDown(with: try TabsEvents.mouse(.leftMouseDown, flags: .control))
        dragged = true
        chip.mouseDown(with: try TabsEvents.mouse(.leftMouseDown))
        #expect(chip.accessibilityPerformPress())
        #expect(toggles == 3)
        #expect(chip.menu(for: try TabsEvents.mouse(.rightMouseDown)) == nil)
        chip.menuProvider = { NSMenu(title: "Group") }
        #expect(chip.menu(for: try TabsEvents.mouse(.rightMouseDown))?.title == "Group")
    }
}
