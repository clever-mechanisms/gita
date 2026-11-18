import Testing

@testable import GitaCore

/// `x` is the dragged item's left edge; the others are compared as if the dragged one had left its place.
struct TabReorderTests {
    typealias Item = TabReorder.Item<String>
    /// Lays items out 100 wide (chips 40) with no gaps, as the strip would.
    private func strip(_ kinds: [TabReorder.Kind<String>]) -> [Item] {
        var x = 0.0
        return kinds.map { kind in
            let width: Double = if case .chip = kind { 40 } else { 100 }
            defer { x += width }
            return Item(kind, minX: x, maxX: x + width)
        }
    }

    // a  b  c  — ungrouped tabs at 0, 100, 200
    @Test func ungroupedTabPassesANeighbourHalfwayOverIt() {
        let groups: [String?] = [nil, nil, nil]
        let items = strip([.tab(0, group: nil), .tab(1, group: nil), .tab(2, group: nil)])
        // a moved 40 right is still first; 60 right it has passed b.
        #expect(TabReorder.dropTab(0, at: 40, groups: groups, items: items).order == [0, 1, 2])
        #expect(TabReorder.dropTab(0, at: 60, groups: groups, items: items).order == [1, 0, 2])
        #expect(TabReorder.dropTab(0, at: 160, groups: groups, items: items).order == [1, 2, 0])
        // c moved left the same distances.
        #expect(TabReorder.dropTab(2, at: 160, groups: groups, items: items).order == [0, 1, 2])
        #expect(TabReorder.dropTab(2, at: 140, groups: groups, items: items).order == [0, 2, 1])
        #expect(TabReorder.dropTab(2, at: 40, groups: groups, items: items).order == [2, 0, 1])
        #expect(TabReorder.dropTab(1, at: 110, groups: groups, items: items).group == nil)
    }

    // a  [G] b c  d — a 0…100, chip 100…140, b 140…240, c 240…340, d 340…440
    private let grouped: [String?] = [nil, "G", "G", nil]
    private var groupedItems: [Item] {
        strip([
            .tab(0, group: nil), .chip("G", collapsed: false), .tab(1, group: "G"), .tab(2, group: "G"),
            .tab(3, group: nil),
        ])
    }

    @Test func tabDroppedAmongAGroupsTabsJoinsIt() {
        // d over the second half of b.
        let drop = TabReorder.dropTab(3, at: 250, groups: grouped, items: groupedItems)
        #expect(drop.order == [0, 1, 3, 2])
        #expect(drop.group == "G")
    }
    @Test func tabDroppedRightAfterTheChipJoinsAtTheFront() {
        // a past the chip's middle (20 once a has left), not past b's (90).
        let drop = TabReorder.dropTab(0, at: 30, groups: grouped, items: groupedItems)
        #expect(drop.order == [0, 1, 2, 3])
        #expect(drop.group == "G")
    }
    @Test func tabDroppedBeforeTheChipIsUngrouped() {
        // b left of the chip's middle (120) but right of a's (50): out of the group, in front of the chip.
        let drop = TabReorder.dropTab(1, at: 80, groups: grouped, items: groupedItems)
        #expect(drop.order == [0, 1, 2, 3])
        #expect(drop.group == nil)
        // Left of a's middle it goes first.
        #expect(TabReorder.dropTab(1, at: 30, groups: grouped, items: groupedItems).order == [1, 0, 2, 3])
    }
    @Test func atAGroupsTrailingEdgeATabKeepsTheGroupItHad() {
        // b past c (c's middle 190 once b has left), not past d's (290): stays in G, now last in it.
        let member = TabReorder.dropTab(1, at: 220, groups: grouped, items: groupedItems)
        #expect(member.order == [0, 2, 1, 3])
        #expect(member.group == "G")
        // a dropped in the same gap does not join.
        let outsider = TabReorder.dropTab(0, at: 220, groups: grouped, items: groupedItems)
        #expect(outsider.order == [1, 2, 0, 3])
        #expect(outsider.group == nil)
    }
    @Test func groupedTabDraggedPastTheEndLeavesTheGroup() {
        let drop = TabReorder.dropTab(2, at: 300, groups: grouped, items: groupedItems)
        #expect(drop.order == [0, 1, 3, 2])
        #expect(drop.group == nil)
    }
    @Test func tabDroppedAfterACollapsedGroupGoesPastItsHiddenTabs() {
        // a  [G·2]  d — b and c hidden; a 0…100, chip 100…140, d 140…240.
        let items = strip([.tab(0, group: nil), .chip("G", collapsed: true), .tab(3, group: nil)])
        let drop = TabReorder.dropTab(0, at: 50, groups: grouped, items: items)
        #expect(drop.order == [1, 2, 0, 3])
        #expect(drop.group == nil)
        // d dropped before the collapsed chip goes before its hidden tabs.
        let back = TabReorder.dropTab(3, at: 80, groups: grouped, items: items)
        #expect(back.order == [0, 3, 1, 2])
        #expect(back.group == nil)
    }

    @Test func groupMovesAsABlockPastAnUngroupedTab() {
        // G spans 100…340; once it has left, d sits at 100…200.
        #expect(TabReorder.dropGroup("G", at: 160, groups: grouped, items: groupedItems) == [0, 3, 1, 2])
        #expect(TabReorder.dropGroup("G", at: 20, groups: grouped, items: groupedItems) == [1, 2, 0, 3])
        #expect(TabReorder.dropGroup("G", at: 120, groups: grouped, items: groupedItems) == [0, 1, 2, 3])
    }
    @Test func groupNeverLandsInsideAnotherGroup() {
        // [G] a b  [H] c d  e — G 0…240, H 240…480, e 480…580.
        let groups: [String?] = ["G", "G", "H", "H", nil]
        let items = strip([
            .chip("G", collapsed: false), .tab(0, group: "G"), .tab(1, group: "G"),
            .chip("H", collapsed: false), .tab(2, group: "H"), .tab(3, group: "H"), .tab(4, group: nil),
        ])
        // Once G has left, H is 0…240 (middle 120): G is not past it at 100 …
        #expect(TabReorder.dropGroup("G", at: 100, groups: groups, items: items) == [0, 1, 2, 3, 4])
        // … and past it at 130, after the whole of H, never between c and d.
        #expect(TabReorder.dropGroup("G", at: 130, groups: groups, items: items) == [2, 3, 0, 1, 4])
        // H dragged to the front.
        #expect(TabReorder.dropGroup("H", at: 50, groups: groups, items: items) == [2, 3, 0, 1, 4])
    }
    @Test func collapsedGroupMovesWithItsHiddenTabs() {
        // a  [G·2]  d — G collapsed (100…140), dragged past d (100…200 once G has left).
        let items = strip([.tab(0, group: nil), .chip("G", collapsed: true), .tab(3, group: nil)])
        #expect(TabReorder.dropGroup("G", at: 160, groups: grouped, items: items) == [0, 3, 1, 2])
    }

    @Test func tabStepsThroughAGroupOneEdgeAtATime() {
        // a  [G] b c  d: a moving right joins G at the front, swaps with b, with c, then leaves G in place, then
        // passes d.
        var groups = grouped
        var kinds: [TabReorder.Kind<String>] = [
            .tab(0, group: nil), .chip("G", collapsed: false), .tab(1, group: "G"), .tab(2, group: "G"),
            .tab(3, group: nil),
        ]
        var tab = 0
        var seen: [[String?]] = []
        while let step = TabReorder.stepTab(tab, by: 1, groups: groups, items: strip(kinds)) {
            // Re-lay the strip in the new order, as the app would.
            let moved = step.order.map { $0 == tab ? step.group : groups[$0] }
            tab = step.order.firstIndex(of: tab)!
            groups = moved
            kinds = []
            for (index, group) in groups.enumerated() {
                if let group, index == groups.firstIndex(of: group) { kinds.append(.chip(group, collapsed: false)) }
                kinds.append(.tab(index, group: group))
            }
            seen.append(groups.enumerated().map { $0.offset == tab ? "a:\($0.element ?? "-")" : $0.element })
        }
        #expect(
            seen == [
                ["a:G", "G", "G", nil], ["G", "a:G", "G", nil], ["G", "G", "a:G", nil], ["G", "G", "a:-", nil],
                ["G", "G", nil, "a:-"],
            ])
        // And back one step: in front of d, still ungrouped (the next step would rejoin G at its end).
        let back = TabReorder.stepTab(3, by: -1, groups: groups, items: strip(kinds))
        #expect(back?.order == [0, 1, 3, 2])
        #expect(back?.group == nil)
        #expect(
            TabReorder.stepTab(
                0, by: -1, groups: [nil, nil], items: strip([.tab(0, group: nil), .tab(1, group: nil)])) == nil)
    }
    @Test func groupStepsPastOneUnitAtATime() {
        // [G] a b  [H] c d  e
        let groups: [String?] = ["G", "G", "H", "H", nil]
        let items = strip([
            .chip("G", collapsed: false), .tab(0, group: "G"), .tab(1, group: "G"),
            .chip("H", collapsed: false), .tab(2, group: "H"), .tab(3, group: "H"), .tab(4, group: nil),
        ])
        #expect(TabReorder.stepGroup("G", by: 1, groups: groups, items: items) == [2, 3, 0, 1, 4])
        #expect(TabReorder.stepGroup("G", by: -1, groups: groups, items: items).isEmpty)
        #expect(TabReorder.stepGroup("H", by: 1, groups: groups, items: items) == [0, 1, 4, 2, 3])
        #expect(TabReorder.stepGroup("H", by: -1, groups: groups, items: items) == [2, 3, 0, 1, 4])
        // Collapsed: its hidden tabs move with it.
        let collapsed = strip([.tab(0, group: nil), .chip("G", collapsed: true), .tab(3, group: nil)])
        #expect(TabReorder.stepGroup("G", by: 1, groups: grouped, items: collapsed) == [0, 3, 1, 2])
        #expect(TabReorder.stepGroup("G", by: -1, groups: grouped, items: collapsed) == [1, 2, 0, 3])
        #expect(
            TabReorder.stepGroup(
                "G", by: 1, groups: grouped,
                items: strip([.tab(0, group: nil), .chip("G", collapsed: true)]).map { $0 }
            ).isEmpty)
    }
}
