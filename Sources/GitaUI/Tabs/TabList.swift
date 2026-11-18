import Foundation
import GitaCore

/// The tab strip's order, groups and selection, without views. A group's tabs stay side by side; every change keeps
/// the same tab selected.
struct TabList<ID: Hashable> {
    struct Entry: Equatable {
        let id: ID
        var groupID: UUID?
    }
    /// ⌘1…⌘8 choose those tabs, ⌘9 the last one.
    private static var lastShortcut: Int { 9 }

    private(set) var entries: [Entry] = []
    /// In no particular order: the strip shows each where its tabs are.
    private(set) var groups: [TabGroup] = []
    var selectedIndex = 0

    var ids: [ID] { entries.map(\.id) }
    var count: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }
    var groupIDs: [UUID?] { entries.map(\.groupID) }
    var selectedID: ID? { entries.indices.contains(selectedIndex) ? entries[selectedIndex].id : nil }
    func index(of id: ID) -> Int? { entries.firstIndex { $0.id == id } }
    func groupID(of id: ID) -> UUID? { index(of: id).flatMap { entries[$0].groupID } }
    func group(_ id: UUID) -> TabGroup? { groups.first { $0.id == id } }
    func members(of group: UUID) -> [ID] { entries.filter { $0.groupID == group }.map(\.id) }

    // MARK: Tabs

    mutating func append(_ id: ID) { entries.append(Entry(id: id)) }
    /// Removes a tab; the selection stays on the same tab, or the one now at its place (the last one at the end).
    mutating func remove(at index: Int) {
        guard entries.indices.contains(index) else { return }
        entries.remove(at: index)
        if index < selectedIndex {
            selectedIndex -= 1
        } else if selectedIndex >= entries.count {
            selectedIndex = max(0, entries.count - 1)
        }
        prune()
    }
    /// Puts the tabs in `order` (indices into the current order), `moving` into `group`, keeping the selection.
    /// Returns false when nothing changes.
    @discardableResult mutating func reorder(_ order: [Int], moving id: ID? = nil, into group: UUID? = nil) -> Bool {
        let regroups = id.flatMap(index(of:)).map { entries[$0].groupID != group } ?? false
        guard order != Array(entries.indices) || regroups else { return false }
        guard order.sorted() == Array(entries.indices) else { return false }
        keepingSelection { list in
            list.entries = order.map { list.entries[$0] }
            if let id, let moved = list.index(of: id) { list.entries[moved].groupID = group }
        }
        prune()
        normalize()
        return true
    }
    /// The tab `number` chooses with ⌘: 1…8 count from the start, 9 is the last.
    func index(forShortcut number: Int) -> Int? {
        guard number >= 1, !entries.isEmpty else { return nil }
        let index = number >= Self.lastShortcut ? entries.count - 1 : number - 1
        return entries.indices.contains(index) ? index : nil
    }
    func shortcut(at index: Int) -> Int? {
        if index < Self.lastShortcut - 1 { return index + 1 }
        return index == entries.count - 1 ? Self.lastShortcut : nil
    }

    // MARK: Groups

    /// Adds `members` (those not in a group yet) to `group`; false when none could join.
    @discardableResult mutating func restore(_ group: TabGroup, members: [Int]) -> Bool {
        let joining = members.filter { entries.indices.contains($0) && entries[$0].groupID == nil }
        guard !joining.isEmpty else { return false }
        groups.append(group)
        for index in joining { entries[index].groupID = group.id }
        return true
    }
    /// A new group in the least used colour (menu order breaks ties).
    mutating func addGroup(named name: String) -> TabGroup {
        let used = groups.map(\.color)
        let color =
            TabColor.allCases.min { left, right in
                used.filter { $0 == left }.count < used.filter { $0 == right }.count
            } ?? .blue
        let group = TabGroup(id: UUID(), name: name, color: color)
        groups.append(group)
        return group
    }
    /// Joins a group: the tab moves to the end of the group's tabs. Joining a collapsed group shows it when the tab
    /// is the selected one.
    mutating func move(_ id: ID, into group: UUID) {
        guard let from = index(of: id), let position = groups.firstIndex(where: { $0.id == group }) else { return }
        let isSelected = from == selectedIndex
        keepingSelection { list in
            var entry = list.entries.remove(at: from)
            entry.groupID = group
            let end = (list.entries.lastIndex { $0.groupID == group }).map { $0 + 1 } ?? min(from, list.entries.count)
            list.entries.insert(entry, at: end)
        }
        if isSelected { groups[position].collapsed = false }
        prune()
        normalize()
    }
    /// Leaves its group: the tab moves just past the group's other tabs.
    mutating func removeFromGroup(_ id: ID) {
        guard let from = index(of: id), let group = entries[from].groupID else { return }
        keepingSelection { list in
            var entry = list.entries.remove(at: from)
            entry.groupID = nil
            let end = (list.entries.lastIndex { $0.groupID == group }).map { $0 + 1 } ?? from
            list.entries.insert(entry, at: end)
        }
        prune()
        normalize()
    }
    mutating func ungroup(_ group: UUID) {
        for index in entries.indices where entries[index].groupID == group { entries[index].groupID = nil }
        prune()
        normalize()
    }
    mutating func setCollapsed(_ collapsed: Bool, group: UUID) {
        guard let position = groups.firstIndex(where: { $0.id == group }) else { return }
        groups[position].collapsed = collapsed
    }
    mutating func rename(_ group: UUID, to name: String) {
        guard let position = groups.firstIndex(where: { $0.id == group }) else { return }
        groups[position].name = name
    }
    mutating func setColor(_ color: TabColor, group: UUID) {
        guard let position = groups.firstIndex(where: { $0.id == group }) else { return }
        groups[position].color = color
    }
    /// Choosing a tab in a collapsed group opens the group; returns true when it did.
    mutating func expandGroup(of index: Int) -> Bool {
        guard entries.indices.contains(index), let group = entries[index].groupID,
            self.group(group)?.collapsed == true
        else { return false }
        setCollapsed(false, group: group)
        return true
    }
    /// The group the selection leaves when `index` is chosen, if it is another group's tab or no group's.
    func groupLeft(choosing index: Int) -> UUID? {
        guard entries.indices.contains(index), entries.indices.contains(selectedIndex), selectedIndex != index,
            let left = entries[selectedIndex].groupID, entries[index].groupID != left
        else { return nil }
        return left
    }
    /// The nearest tab outside `group` to show instead of the selected one: after it, else before it.
    func nearestOutside(_ group: UUID) -> Int? {
        let outside = entries.indices.filter { entries[$0].groupID != group }
        return outside.first { $0 > selectedIndex } ?? outside.last
    }

    /// Keeps each group's tabs side by side, where its first tab is.
    mutating func normalize() {
        let order = TabGrouping.contiguousOrder(groupIDs)
        guard order != Array(entries.indices) else { return }
        keepingSelection { list in list.entries = order.map { list.entries[$0] } }
    }
    /// Drops groups whose tabs have all closed or left.
    mutating func prune() {
        let used = Set(entries.compactMap(\.groupID))
        groups.removeAll { !used.contains($0.id) }
    }
    private mutating func keepingSelection(_ change: (inout Self) -> Void) {
        let selected = selectedID
        change(&self)
        if let selected, let index = index(of: selected) { selectedIndex = index }
    }
}
