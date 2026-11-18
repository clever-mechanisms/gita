/// Where a tab or a whole tab group lands when it is dragged along the tab strip, or moved one place left or right.
///
/// The strip describes what it shows (chips and visible tabs, left to right, at their laid-out places, the moving
/// ones included); a drag adds where the moving item's left edge now is. The result is the new tab order and, for a
/// tab, the group it ends up in. The others are measured as if the dragged item had left its place (the gap closed),
/// so it passes a neighbour once it is over half of it, the same distance either way.
///
/// Rules: a tab joins a group when dropped among that group's tabs or right after its chip; dropped at a group's
/// trailing edge it keeps the group it had; anywhere else it is ungrouped. A group moves as one block and never lands
/// inside another group. One step moves a tab into or out of a group at its edge before it moves past anything.
public enum TabReorder {
    public enum Kind<ID: Hashable>: Equatable {
        /// A group's chip; a collapsed group's tabs are hidden and not listed.
        case chip(ID, collapsed: Bool)
        /// A visible tab, by its index in the tab order.
        case tab(Int, group: ID?)
    }
    public struct Item<ID: Hashable>: Equatable {
        public var kind: Kind<ID>
        public var minX: Double, maxX: Double
        public init(_ kind: Kind<ID>, minX: Double, maxX: Double) {
            self.kind = kind
            self.minX = minX
            self.maxX = maxX
        }
        var midX: Double { (minX + maxX) / 2 }
    }

    // MARK: Tabs

    /// Drops tab `index` with its left edge at `x`. `groups` is each tab's group, in tab order.
    public static func dropTab<ID>(
        _ index: Int, at x: Double, groups: [ID?], items: [Item<ID>]
    ) -> (order: [Int], group: ID?) {
        let others = closingGap(items) { isTab($0, index) }
        let gap = others.firstIndex { x < $0.midX } ?? others.count
        let choices = groupChoices(at: gap, in: others)
        // At a trailing edge (two choices) the tab keeps the group it had.
        let group = choices.count > 1 ? (choices.contains(groups[index]) ? groups[index] : nil) : choices[0]
        return (place(index, gap: gap, others: others, groups: groups), group)
    }

    /// Moves tab `index` one place left (`step` -1) or right (+1); nil when it cannot go further.
    public static func stepTab<ID>(
        _ index: Int, by step: Int, groups: [ID?], items: [Item<ID>]
    ) -> (order: [Int], group: ID?)? {
        guard let own = items.firstIndex(where: { isTab($0.kind, index) }) else { return nil }
        let others = items.filter { !isTab($0.kind, index) }
        // Every place the tab can be, left to right: a gap between the others, with each group it can be in there.
        let states = (0...others.count).flatMap { gap in groupChoices(at: gap, in: others).map { (gap, $0) } }
        guard let current = states.firstIndex(where: { $0.0 == own && $0.1 == groups[index] }),
            states.indices.contains(current + step)
        else { return nil }
        let (gap, group) = states[current + step]
        return (place(index, gap: gap, others: others, groups: groups), group)
    }

    // MARK: Groups

    /// Drops group `id` (its chip and tabs) with the block's left edge at `x`.
    public static func dropGroup<ID>(_ id: ID, at x: Double, groups: [ID?], items: [Item<ID>]) -> [Int] {
        let others = closingGap(items) { isGroup($0, id) }
        let parts = units(others)
        let unit = parts.firstIndex { x < ($0.minX + $0.maxX) / 2 } ?? parts.count
        return placeGroup(id, before: unit, units: parts, others: others, groups: groups)
    }

    /// Moves group `id` one place left (-1) or right (+1), past one ungrouped tab or whole group; empty at either end.
    public static func stepGroup<ID>(_ id: ID, by step: Int, groups: [ID?], items: [Item<ID>]) -> [Int] {
        guard let own = items.firstIndex(where: { isGroup($0.kind, id) }) else { return [] }
        let others = items.filter { !isGroup($0.kind, id) }
        let parts = units(others)
        // The group sits before the first unit that starts after it.
        let current = parts.firstIndex { $0.start >= own } ?? parts.count
        let target = current + step
        guard target >= 0, target <= parts.count, target != current else { return [] }
        return placeGroup(id, before: target, units: parts, others: others, groups: groups)
    }

    // MARK: Shared

    private static func isTab<ID>(_ kind: Kind<ID>, _ index: Int) -> Bool {
        if case .tab(let tab, _) = kind { tab == index } else { false }
    }
    private static func isGroup<ID>(_ kind: Kind<ID>, _ id: ID) -> Bool {
        switch kind {
        case .chip(let group, _): group == id
        case .tab(_, let group): group == id
        }
    }
    /// The groups a tab dropped in `gap` (before `others[gap]`) can be in: right after an open chip or between two
    /// of a group's tabs only that group; at a group's trailing edge that group or none; elsewhere none.
    private static func groupChoices<ID>(at gap: Int, in others: [Item<ID>]) -> [ID?] {
        let left = gap > 0 ? others[gap - 1].kind : nil
        let right = gap < others.count ? others[gap].kind : nil
        switch left {
        case .chip(let id, collapsed: false)?: return [id]
        case .tab(_, group: let id?)?:
            if case .tab(_, group: let next)? = right, next == id { return [id] }
            return [id, nil]
        default: return [nil]
        }
    }
    /// The tab order with tab `index` moved into `gap`.
    private static func place<ID>(_ index: Int, gap: Int, others: [Item<ID>], groups: [ID?]) -> [Int] {
        var order = groups.indices.filter { $0 != index }
        let before = firstTab(from: gap, in: others, groups: groups, excluding: [index])
        order.insert(index, at: before.flatMap { order.firstIndex(of: $0) } ?? order.count)
        return order
    }
    /// Whole groups and ungrouped tabs: the places a group can go between.
    private static func units<ID>(_ others: [Item<ID>]) -> [(start: Int, minX: Double, maxX: Double)] {
        var units: [(start: Int, minX: Double, maxX: Double)] = []
        var current: ID?
        for (offset, item) in others.enumerated() {
            switch item.kind {
            case .chip(let group, _):
                current = group
                units.append((offset, item.minX, item.maxX))
            case .tab(_, let group):
                if let group, group == current, let last = units.last {
                    units[units.count - 1] = (last.start, last.minX, item.maxX)
                } else {
                    current = nil
                    units.append((offset, item.minX, item.maxX))
                }
            }
        }
        return units
    }
    /// The tab order with group `id`'s tabs moved, in their order, in front of `units[unit]` (or to the end).
    private static func placeGroup<ID>(
        _ id: ID, before unit: Int, units: [(start: Int, minX: Double, maxX: Double)],
        others: [Item<ID>], groups: [ID?]
    ) -> [Int] {
        let members = groups.indices.filter { groups[$0] == id }
        let before =
            units.indices.contains(unit)
            ? firstTab(from: units[unit].start, in: others, groups: groups, excluding: Set(members)) : nil
        var order = groups.indices.filter { groups[$0] != id }
        order.insert(contentsOf: members, at: before.flatMap { order.firstIndex(of: $0) } ?? order.count)
        return order
    }
    /// The items other than the dragged ones, those after them moved left by the dragged span's width.
    private static func closingGap<ID>(_ items: [Item<ID>], dragged: (Kind<ID>) -> Bool) -> [Item<ID>] {
        let moving = items.filter { dragged($0.kind) }
        guard let start = moving.map(\.minX).min(), let end = moving.map(\.maxX).max() else { return items }
        return items.filter { !dragged($0.kind) }.map { item in
            item.minX >= end ? Item(item.kind, minX: item.minX - (end - start), maxX: item.maxX - (end - start)) : item
        }
    }
    /// The first tab shown at or after `position` (a chip stands for its group's tabs, hidden or not).
    private static func firstTab<ID>(
        from position: Int, in items: [Item<ID>], groups: [ID?], excluding: Set<Int>
    ) -> Int? {
        guard position < items.count else { return nil }
        for item in items[position...] {
            switch item.kind {
            case .tab(let tab, _): return tab
            case .chip(let group, _):
                if let tab = groups.indices.first(where: { groups[$0] == group && !excluding.contains($0) }) {
                    return tab
                }
            }
        }
        return nil
    }
}
