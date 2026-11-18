import AppKit
import GitaCore
import Testing

@testable import GitaUI

@MainActor
@Suite("Tabs: strip view")
struct TabsStripViewTests {
    /// A strip 600 wide in a window, with a tab, a group chip with two tabs, and another tab.
    @MainActor private final class Fixture {
        let window: TabsScriptedWindow
        let strip = TabStripView()
        let tabs = (0..<4).map { _ in NSView() }
        let chip = TabGroupChipView()
        var group = TabGroup(id: UUID(), name: "Group", color: .orange)
        var drags: [(TabStripView.DragSubject, CGFloat)] = []
        var ends = 0

        init() {
            UITestSupport.bootstrap()
            window = TabsScriptedWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 40), styleMask: [.titled], backing: .buffered,
                defer: false)
            window.isReleasedWhenClosed = false
            window.contentView?.addSubview(strip)
            strip.onLayoutWidth = { 600 }
            strip.onDrag = { [weak self] subject, left in self?.drags.append((subject, left)) }
            strip.onDragEnd = { [weak self] in self?.ends += 1 }
            chip.update(group, count: 2, agents: [])
            setItems()
        }
        func setItems() {
            strip.setItems([
                .tab(tabs[0], group: nil), .chip(chip, group), .tab(tabs[1], group: group),
                .tab(tabs[2], group: group), .tab(tabs[3], group: nil),
            ])
        }
        /// Queues a mouse event for the window's next `nextEvent(matching:)`.
        func post(_ type: NSEvent.EventType, x: CGFloat) throws {
            window.script.append(try TabsEvents.mouse(type, at: NSPoint(x: x, y: 10), in: window))
        }
    }

    @Test func laysOutItemsWithGroupLines() throws {
        let fixture = Fixture()
        let strip = fixture.strip
        #expect(strip.isFlipped)
        #expect(strip.layoutItems.count == 5)
        #expect(strip.frame.height == Theme.tabHeight + 3)
        #expect(fixture.tabs.allSatisfy { $0.superview === strip && !$0.isHidden })
        let lines = strip.subviews.filter { $0 is FillView }
        #expect(lines.count == 1)
        let item = try #require(strip.layoutItems.first)
        #expect(item.0.groupID == nil)
        #expect(strip.layoutItems[1].0.groupID == fixture.group.id)
        #expect(strip.layoutItems[2].0.view === fixture.tabs[1])
        // Collapsing hides the group's tabs and its line.
        fixture.group.collapsed = true
        fixture.setItems()
        #expect(fixture.tabs[1].isHidden && fixture.tabs[2].isHidden)
        #expect(strip.layoutItems.count == 3)
        #expect(!strip.subviews.contains { $0 is FillView })
        // A tab that leaves the strip leaves its superview.
        strip.setItems([.tab(fixture.tabs[0], group: nil)])
        #expect(fixture.tabs[3].superview == nil)
        strip.relayout(animated: true)
    }

    @Test func draggingATabMovesItAndReports() throws {
        let fixture = Fixture()
        let strip = fixture.strip
        let start = try #require(strip.beginDrag(.tab(fixture.tabs[0])))
        #expect(start == 0)
        #expect(strip.isDragging)
        strip.moveDrag(.tab(fixture.tabs[0]), to: 100)
        #expect(fixture.tabs[0].frame.minX == 100)
        strip.moveDrag(.tab(fixture.tabs[0]), to: 10_000)
        #expect(fixture.drags.last?.1 == strip.bounds.width - fixture.tabs[0].frame.width)
        strip.relayout()
        strip.endDrag()
        #expect(!strip.isDragging)
        #expect(fixture.ends == 1)
        #expect(strip.layoutItems.first?.1.minX == 0)
        #expect(strip.beginDrag(.tab(NSView())) == nil)
        strip.moveDrag(.tab(fixture.tabs[0]), to: 5)
        #expect(fixture.drags.count == 2)
    }

    @Test func draggingAGroupMovesItsChipAndTabs() throws {
        let fixture = Fixture()
        let strip = fixture.strip
        let chipStart = fixture.chip.frame.minX
        let left = try #require(strip.beginDrag(.group(fixture.group.id)))
        #expect(left == chipStart)
        strip.moveDrag(.group(fixture.group.id), to: chipStart + 50)
        #expect(fixture.chip.frame.minX == chipStart + 50)
        #expect(fixture.tabs[1].frame.minX > fixture.chip.frame.maxX)
        strip.endDrag()
        #expect(strip.beginDrag(.group(UUID())) == nil)
    }

    @Test func trackingFollowsQueuedMouseEvents() throws {
        let fixture = Fixture()
        let strip = fixture.strip
        let down = try TabsEvents.mouse(.leftMouseDown, at: NSPoint(x: 20, y: 10), in: fixture.window)
        // A press released without moving is a click.
        try fixture.post(.leftMouseDragged, x: 22)
        try fixture.post(.leftMouseUp, x: 22)
        #expect(!strip.trackDrag(.tab(fixture.tabs[0]), from: down))
        // Moving far enough drags.
        try fixture.post(.leftMouseDragged, x: 22)
        try fixture.post(.leftMouseDragged, x: 80)
        try fixture.post(.leftMouseDragged, x: 120)
        try fixture.post(.leftMouseUp, x: 120)
        #expect(strip.trackDrag(.tab(fixture.tabs[0]), from: down))
        #expect(fixture.drags.count == 2)
        #expect(fixture.ends == 1)
        // Nothing to drag: cancelled.
        try fixture.post(.leftMouseDragged, x: 80)
        try fixture.post(.leftMouseUp, x: 80)
        #expect(!strip.trackDrag(.tab(NSView()), from: down))
        #expect(fixture.window.script.map(\.type) == [.leftMouseUp])
        // Without a window there is nothing to follow.
        #expect(!TabStripView().trackDrag(.tab(fixture.tabs[0]), from: down))
    }
}

/// A window whose event loop replays queued events instead of the application's queue.
final class TabsScriptedWindow: NSWindow {
    var script: [NSEvent] = []

    override func nextEvent(matching _: NSEvent.EventTypeMask) -> NSEvent? {
        script.isEmpty ? nil : script.removeFirst()
    }
}
