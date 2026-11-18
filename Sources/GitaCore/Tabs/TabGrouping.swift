/// Ordering rule for grouped tabs: a group's members sit side by side, where its first member was, in their own
/// relative order; ungrouped tabs keep their places around the groups.
public enum TabGrouping {
    /// The new order as indices into `groups` (one optional group ID per tab, in tab order).
    public static func contiguousOrder<ID: Hashable>(_ groups: [ID?]) -> [Int] {
        var members: [ID: [Int]] = [:]
        for (index, group) in groups.enumerated() { if let group { members[group, default: []].append(index) } }
        var order: [Int] = []
        order.reserveCapacity(groups.count)
        var emitted = Set<ID>()
        for (index, group) in groups.enumerated() {
            guard let group else {
                order.append(index)
                continue
            }
            if emitted.insert(group).inserted { order.append(contentsOf: members[group] ?? []) }
        }
        return order
    }
}
