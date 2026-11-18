import Testing

@testable import GitaCore

struct TabGroupingTests {
    @Test func membersGatherWhereTheGroupFirstAppears() {
        // a(G) b c(G) d(H) e(G) f(H)  →  a c e b d f
        let groups: [String?] = ["G", nil, "G", "H", "G", "H"]
        #expect(TabGrouping.contiguousOrder(groups) == [0, 2, 4, 1, 3, 5])
    }
    @Test func alreadyContiguousOrderIsUnchanged() {
        let groups: [Int?] = [nil, 1, 1, nil, 2, 2, nil]
        #expect(TabGrouping.contiguousOrder(groups) == Array(0..<7))
    }
    @Test func emptyAndUngroupedTabsKeepTheirOrder() {
        let empty: [Int?] = []
        #expect(TabGrouping.contiguousOrder(empty).isEmpty)
        #expect(TabGrouping.contiguousOrder([nil, nil, nil] as [Int?]) == [0, 1, 2])
    }
}
