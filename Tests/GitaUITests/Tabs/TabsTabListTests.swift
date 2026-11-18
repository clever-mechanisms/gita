import Foundation
import Testing

@testable import GitaUI

@Suite("Tabs: TabList")
struct TabsTabListTests {
    /// A list of tabs "a"… with `count` entries.
    private static func list(_ count: Int, selected: Int = 0) -> TabList<String> {
        var list = TabList<String>()
        for index in 0..<count { list.append(String(UnicodeScalar(UInt8(97 + index)))) }
        list.selectedIndex = selected
        return list
    }

    @Test func emptyListHasNoSelectionOrShortcuts() {
        let list = TabList<String>()
        #expect(list.isEmpty)
        #expect(list.selectedID == nil)
        #expect(list.index(forShortcut: 1) == nil)
        #expect(list.index(forShortcut: 0) == nil)
    }

    @Test(arguments: [
        (removing: 0, selected: 2, expected: 1),
        (removing: 2, selected: 2, expected: 2),
        (removing: 3, selected: 3, expected: 2),
        (removing: 3, selected: 1, expected: 1),
        (removing: 9, selected: 1, expected: 1),
    ])
    func removeKeepsTheSelection(removing: Int, selected: Int, expected: Int) {
        var list = Self.list(4, selected: selected)
        list.remove(at: removing)
        #expect(list.selectedIndex == expected)
    }

    @Test func removingTheLastTabLeavesSelectionAtZero() {
        var list = Self.list(1)
        list.remove(at: 0)
        #expect(list.selectedIndex == 0)
        #expect(list.isEmpty)
    }

    @Test(arguments: [
        (count: 3, number: 1, expected: Optional(0)),
        (count: 3, number: 3, expected: Optional(2)),
        (count: 3, number: 4, expected: Optional<Int>.none),
        (count: 3, number: 9, expected: Optional(2)),
        (count: 12, number: 9, expected: Optional(11)),
        (count: 12, number: 12, expected: Optional(11)),
    ])
    func shortcutIndices(count: Int, number: Int, expected: Int?) {
        #expect(Self.list(count).index(forShortcut: number) == expected)
    }

    @Test func shortcutsAtIndices() {
        let list = Self.list(12)
        #expect(list.shortcut(at: 0) == 1)
        #expect(list.shortcut(at: 7) == 8)
        #expect(list.shortcut(at: 8) == nil)
        #expect(list.shortcut(at: 11) == 9)
    }

    @Test func reorderMovesAndKeepsSelection() {
        var list = Self.list(3, selected: 0)
        let step1 = list.reorder([0, 1, 2])
        #expect(!step1)
        let step2 = list.reorder([0, 0, 1])
        #expect(!step2)
        let step3 = list.reorder([2, 0, 1])
        #expect(step3)
        #expect(list.ids == ["c", "a", "b"])
        #expect(list.selectedID == "a")
    }

    @Test func reorderIntoAGroupRegroupsEvenInPlace() throws {
        var list = Self.list(3)
        let group = list.addGroup(named: "G")
        let step4 = list.reorder([0, 1, 2], moving: "b", into: group.id)
        #expect(step4)
        #expect(list.groupID(of: "b") == group.id)
        let step5 = list.reorder([0, 1, 2], moving: "b", into: group.id)
        #expect(!step5)
        #expect(list.members(of: group.id) == ["b"])
        #expect(try #require(list.group(group.id)).name == "G")
    }

    @Test func addGroupPicksTheLeastUsedColour() {
        var list = Self.list(1)
        let first = list.addGroup(named: "one")
        let second = list.addGroup(named: "two")
        #expect(first.color == TabColor.allCases[0])
        #expect(second.color == TabColor.allCases[1])
    }

    @Test func moveIntoAGroupGoesToTheEndOfItsTabs() {
        var list = Self.list(4, selected: 3)
        let group = list.addGroup(named: "G")
        list.move("a", into: group.id)
        list.setCollapsed(true, group: group.id)
        list.move("d", into: group.id)
        #expect(list.ids == ["a", "d", "b", "c"])
        #expect(list.selectedID == "d")
        // The selected tab joining a collapsed group shows the group.
        #expect(list.group(group.id)?.collapsed == false)
        list.move("zz", into: group.id)
        list.move("b", into: UUID())
        #expect(list.ids == ["a", "d", "b", "c"])
    }

    @Test func removeFromGroupPlacesTheTabPastTheGroup() {
        var list = Self.list(4)
        let group = list.addGroup(named: "G")
        list.move("a", into: group.id)
        list.move("b", into: group.id)
        list.removeFromGroup("a")
        #expect(list.ids == ["b", "a", "c", "d"])
        #expect(list.groupID(of: "a") == nil)
        list.removeFromGroup("b")
        #expect(list.groups.isEmpty)
        list.removeFromGroup("c")
        #expect(list.ids == ["b", "a", "c", "d"])
    }

    @Test func ungroupRenameAndRecolour() {
        var list = Self.list(2)
        let group = list.addGroup(named: "G")
        list.move("a", into: group.id)
        list.rename(group.id, to: "New")
        list.setColor(.pink, group: group.id)
        #expect(list.group(group.id)?.name == "New")
        #expect(list.group(group.id)?.color == .pink)
        list.rename(UUID(), to: "x")
        list.setColor(.red, group: UUID())
        list.setCollapsed(true, group: UUID())
        list.ungroup(group.id)
        #expect(list.groups.isEmpty)
        #expect(list.groupIDs == [nil, nil])
    }

    @Test func expandGroupOpensACollapsedGroupOnce() {
        var list = Self.list(2)
        let group = list.addGroup(named: "G")
        list.move("b", into: group.id)
        let step6 = list.expandGroup(of: 1)
        #expect(!step6)
        list.setCollapsed(true, group: group.id)
        let step7 = list.expandGroup(of: 0)
        #expect(!step7)
        let step8 = list.expandGroup(of: 7)
        #expect(!step8)
        let step9 = list.expandGroup(of: 1)
        #expect(step9)
        let step10 = list.expandGroup(of: 1)
        #expect(!step10)
    }

    @Test func groupLeftAndNearestOutside() {
        var list = Self.list(4, selected: 1)
        let group = list.addGroup(named: "G")
        list.move("b", into: group.id)
        list.move("c", into: group.id)
        // Order: a, b, c (grouped), d; the selection is b.
        #expect(list.selectedID == "b")
        #expect(list.groupLeft(choosing: 0) == group.id)
        #expect(list.groupLeft(choosing: 2) == nil)
        #expect(list.groupLeft(choosing: 1) == nil)
        #expect(list.groupLeft(choosing: 9) == nil)
        #expect(list.nearestOutside(group.id) == 3)
        list.selectedIndex = 3
        #expect(list.groupLeft(choosing: 0) == nil)
        #expect(list.nearestOutside(group.id) == 3)
    }

    @Test func restoreJoinsOnlyUngroupedMembers() {
        var list = Self.list(3)
        let first = TabGroup(id: UUID(), name: "A", color: .red)
        let second = TabGroup(id: UUID(), name: "B", color: .blue)
        let step11 = list.restore(first, members: [0, 2])
        #expect(step11)
        let step12 = list.restore(second, members: [0, 5])
        #expect(!step12)
        list.normalize()
        #expect(list.ids == ["a", "c", "b"])
        #expect(list.groups.map(\.id) == [first.id])
    }
}
