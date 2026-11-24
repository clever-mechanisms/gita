import AppKit
import GitaCore
import Testing

@testable import GitaUI

@MainActor
@Suite("Tabs: strip layout")
struct TabsLayoutTests {
    private typealias Entry = TabStripLayout.Entry

    @Test func fewTabsAreWideAndFillTheStrip() {
        let slots = TabStripLayout.slots([Entry(kind: .tab), Entry(kind: .tab)], available: 1_000, height: 30)
        #expect(slots.frames[0] == CGRect(x: 0, y: 4, width: 230, height: 26))
        #expect(slots.frames[1] == CGRect(x: 232, y: 4, width: 230, height: 26))
        #expect(slots.width == 1_000)
    }

    @Test func manyTabsScrollAtTheMinimumWidth() {
        let entries = Array(repeating: Entry(kind: .tab), count: 10)
        let slots = TabStripLayout.slots(entries, available: 500, height: 30)
        #expect(slots.frames.allSatisfy { $0?.width == TabStripLayout.minimumTabWidth })
        #expect(Int(slots.width) == 10 * 132 + 9 * 2)
    }

    @Test func emptyStripIsAsWideAsAvailable() {
        let slots = TabStripLayout.slots([], available: 300, height: 30)
        #expect(slots.frames.isEmpty)
        #expect(slots.width == 300)
    }

    @Test func groupsGetChipsGapsAndLines() throws {
        let group = UUID()
        let entries = [
            Entry(kind: .tab),
            Entry(kind: .chip(width: 40), groupID: group, color: .green),
            Entry(kind: .tab, groupID: group),
            Entry(kind: .tab, groupID: group),
            Entry(kind: .tab),
        ]
        let slots = TabStripLayout.slots(entries, available: 300, height: 30)
        let frames = slots.frames.compactMap { $0 }
        #expect(frames.count == 5)
        #expect(frames[1].minX == frames[0].maxX + TabStripLayout.groupGap)
        #expect(frames[1].height == 18)
        #expect(frames[2].minX == frames[1].maxX + TabStripLayout.afterChipGap)
        #expect(frames[3].minX == frames[2].maxX + TabStripLayout.gap)
        #expect(frames[4].minX == frames[3].maxX + TabStripLayout.groupGap)
        let lines = TabStripLayout.lines(entries, frames: slots.frames)
        let line = try #require(lines.first)
        #expect(lines.count == 1)
        #expect(line == TabStripLayout.Line(color: .green, minX: frames[1].minX, maxX: frames[3].maxX))
    }

    @Test func collapsedGroupsHideTheirTabsAndDrawNoLine() {
        let group = UUID()
        let entries = [
            Entry(kind: .chip(width: 30), groupID: group, collapsed: true, color: .red),
            Entry(kind: .tab, groupID: group, collapsed: true),
            Entry(kind: .tab),
        ]
        #expect(entries[0].isChip && !entries[0].isHidden)
        #expect(entries[1].isHidden)
        let slots = TabStripLayout.slots(entries, available: 300, height: 30)
        #expect(slots.frames[1] == nil)
        #expect(TabStripLayout.lines(entries, frames: slots.frames).isEmpty)
        // A tab of a group without a chip in front draws nothing either.
        let orphan = [Entry(kind: .tab, groupID: group)]
        #expect(TabStripLayout.lines(orphan, frames: [CGRect(x: 0, y: 0, width: 10, height: 10)]).isEmpty)
    }

    @Test(arguments: [
        (start: CGFloat(100), x: CGFloat(103), expected: DragTracker.Step.pending),
        (start: 100, x: 96, expected: .pending),
    ])
    func smallMovesStayClicks(start: CGFloat, x: CGFloat, expected: DragTracker.Step) {
        var tracker = DragTracker(start: start)
        let step = tracker.move(to: x) { 0 }
        #expect(step == expected)
        #expect(!tracker.didDrag)
    }

    @Test func dragFollowsThePointerFromWhereItBegan() {
        var tracker = DragTracker(start: 100)
        var begun = 0
        let first = tracker.move(to: 110) {
            begun += 1
            return 40
        }
        #expect(first == .moved(50))
        let second = tracker.move(to: 80) { 999 }
        #expect(second == .moved(20))
        #expect(begun == 1)
        #expect(tracker.didDrag)
        var cancelled = DragTracker(start: 0)
        let cancelStep = cancelled.move(to: 50) { nil }
        #expect(cancelStep == .cancelled)
    }

    @Test(arguments: [
        (left: CGFloat(-5), expected: CGFloat(0)),
        (left: 50, expected: 50),
        (left: 500, expected: 100),
    ])
    func clampKeepsTheSpanOnTheStrip(left: CGFloat, expected: CGFloat) {
        #expect(DragTracker.clamp(left, span: 100, width: 200) == expected)
        #expect(DragTracker.clamp(left, span: 300, width: 200) == 0)
    }

    @Test func titlesAddTheParentWhenNamesClash() {
        let entries = [
            TabTitles.Entry(root: URL(fileURLWithPath: "/a/app"), repositoryRoot: URL(fileURLWithPath: "/a/app")),
            TabTitles.Entry(root: URL(fileURLWithPath: "/b/app"), repositoryRoot: URL(fileURLWithPath: "/b/app")),
            TabTitles.Entry(root: URL(fileURLWithPath: "/c/lib"), repositoryRoot: nil),
            TabTitles.Entry(root: URL(fileURLWithPath: "/d/lib"), repositoryRoot: URL(fileURLWithPath: "/d/lib")),
            TabTitles.Entry(root: nil, repositoryRoot: nil),
        ]
        let titles = TabTitles(entries)
        #expect(titles.name(at: 0, isLoading: false) == "a/app")
        #expect(titles.name(at: 1, isLoading: false) == "b/app")
        #expect(titles.name(at: 2, isLoading: false) == "c/lib")
        #expect(titles.name(at: 3, isLoading: false) == "lib")
        #expect(titles.name(at: 4, isLoading: false) == "Open Repository")
        #expect(titles.name(at: 4, isLoading: true) == "Loading Repository")
        #expect(titles.name(at: 9, isLoading: false) == "Open Repository")
    }

    @Test func aWorktreeTabNamesItsRepositoryAndShortensTheSharedName() {
        let main = URL(fileURLWithPath: "/p/app")
        let windows = URL(fileURLWithPath: "/p/app-windows")
        let fix = URL(fileURLWithPath: "/w/fix")
        let titles = TabTitles([
            TabTitles.Entry(root: main, repositoryRoot: main),
            TabTitles.Entry(root: windows, repositoryRoot: windows, mainCheckout: main),
            TabTitles.Entry(root: fix, repositoryRoot: fix, mainCheckout: main),
        ])
        #expect(titles.name(at: 0, isLoading: false) == "app")
        #expect(titles.name(at: 1, isLoading: false) == "app […-windows]")
        #expect(titles.name(at: 1, isLoading: false, selected: true) == "app [app-windows]")
        #expect(titles.name(at: 2, isLoading: false) == "app [fix]")
        #expect(TabTitles.short("App-x", after: "app") == "…-x")
        #expect(TabTitles.short("app", after: "app") == "app")
        #expect(TabTitles.short("other", after: "") == "other")
    }

    @Test func groupNamesAreTrimmedAndCapped() {
        #expect(RepositoryTabsController.groupName("  work \n") == "work")
        #expect(RepositoryTabsController.groupName(String(repeating: "x", count: 80)).count == 60)
        #expect(TabGroup(id: UUID(), name: "", color: .red).displayName == "Unnamed group")
        #expect(TabGroup(id: UUID(), name: "Work", color: .red).displayName == "Work")
    }
}

@MainActor
@Suite("Tabs: colours and tab state")
struct TabsStateTests {
    @Test func everyColourHasATitleColourAndSwatch() {
        let titles = TabColor.allCases.map(\.localizedTitle)
        #expect(titles == ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Pink", "Grey"])
        for color in TabColor.allCases {
            let swatch = color.swatch
            #expect(swatch.size == NSSize(width: 12, height: 12))
            #expect(swatch.accessibilityDescription == color.localizedTitle)
            #expect(swatch.cgImage(forProposedRect: nil, context: nil, hints: nil) != nil)
            _ = color.color
        }
    }

    @Test func plainTabStateHasNoBadge() {
        let state = RepositoryTabState(name: "app")
        #expect(state.badge == .none)
        #expect(state.toolTip == "app")
        #expect(state.accessibilityLabel == "app")
        #expect(state.closeTitle == "Close app")
    }

    @Test func agentStatesMapToTabBadges() {
        let working = RepositoryTabState(name: "app", agent: .working, tool: .codex)
        #expect(working.badge == .none)
        let waiting = RepositoryTabState(name: "app", agent: .needsInput, tool: .codex)
        #expect(waiting.badge == .needsInput)
        let done = RepositoryTabState(name: "app", agent: .done, tool: .codex)
        #expect(done.badge == .done)
        let idle = RepositoryTabState(name: "app", agent: .idle, tool: .codex)
        #expect(idle.badge == .none)
    }

    @Test func toolTipAndAccessibilityListEverything() {
        let state = RepositoryTabState(
            name: "app", branch: "main", path: "/x/app", agent: .working, tool: .claudeCode, shortcut: 3)
        let lines = state.toolTip.components(separatedBy: "\n")
        #expect(lines.count == 5)
        #expect(lines[0] == "app")
        #expect(lines[1] == "/x/app")
        #expect(lines[2] == "main")
        #expect(lines[3].hasPrefix("Claude Code · "))
        #expect(lines[4] == "⌘3")
        #expect(state.accessibilityLabel.hasPrefix("app, main, Claude Code, "))
    }
}
