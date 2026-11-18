import Foundation
import Testing

@testable import GitaCore

struct RepositoryListOrderTests {
    private struct Item: Equatable {
        var name: String
        var rank: Int
    }

    @Test func nameOrderIsFindersOrder() {
        let items = ["beta", "Alpha", "app10", "app2", "Älter", "gamma"].map { Item(name: $0, rank: 0) }
        let sorted = RepositoryListOrder.name.sorted(items, name: \.name, rank: \.rank).map(\.name)
        // Case-insensitive, numbers by value, diacritics next to their base letter.
        #expect(sorted == ["Alpha", "Älter", "app2", "app10", "beta", "gamma"])
    }
    @Test func recentOrderKeepsTheGivenOrder() {
        let items = [Item(name: "z", rank: 3), Item(name: "a", rank: 0), Item(name: "m", rank: 1)]
        #expect(RepositoryListOrder.recent.sorted(items, name: \.name, rank: \.rank) == items)
    }
    @Test func statusOrderRanksThenNames() {
        let items = [
            Item(name: "quiet", rank: 3), Item(name: "b-working", rank: 1), Item(name: "waiting", rank: 0),
            Item(name: "a-working", rank: 1), Item(name: "changed", rank: 2),
        ]
        let sorted = RepositoryListOrder.status.sorted(items, name: \.name, rank: \.rank).map(\.name)
        #expect(sorted == ["waiting", "a-working", "b-working", "changed", "quiet"])
    }
    @Test func equalNamesKeepTheGivenOrder() {
        // Two folders of one name in different places ("parent/name" is shown only in the monitor's names).
        let items = [
            Item(name: "app", rank: 1), Item(name: "web", rank: 5), Item(name: "app", rank: 0),
            Item(name: "app", rank: 2),
        ]
        #expect(RepositoryListOrder.name.sorted(items, name: \.name, rank: \.rank).map(\.rank) == [1, 0, 2, 5])
        #expect(RepositoryListOrder.status.sorted(items, name: \.name, rank: { _ in 0 }).map(\.rank) == [1, 0, 2, 5])
    }
    @Test func statusRankPutsAgentsFirst() {
        #expect(RepositoryListOrder.statusRank(needsInput: true, working: true, hasChanges: true) == 0)
        #expect(RepositoryListOrder.statusRank(needsInput: false, working: true, hasChanges: true) == 1)
        #expect(RepositoryListOrder.statusRank(needsInput: false, working: false, hasChanges: true) == 2)
        #expect(RepositoryListOrder.statusRank(needsInput: false, working: false, hasChanges: false) == 3)
    }
    @Test func unknownStoredValueIsRejected() {
        #expect(RepositoryListOrder(rawValue: "size") == nil)
        #expect(RepositoryListOrder(rawValue: "status") == .status)
    }
}

struct RecentRepositoriesTests {
    @Test func removingMatchesAnySpellingOfThePath() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("recent-\(UUID().uuidString)")
        let real = base.appendingPathComponent("real")
        let link = base.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: base) }
        let list = [link.path, "/tmp/other", real.path + "/", base.path + "/x/../real", "/tmp/kept"]
        #expect(RecentRepositories.removing([real.path], from: list) == ["/tmp/other", "/tmp/kept"])
        #expect(RecentRepositories.removing([link.path + "/"], from: list) == ["/tmp/other", "/tmp/kept"])
        #expect(RecentRepositories.removing([], from: list) == list)
    }
    @Test func insertingMovesThePathFirstAndKeepsTwelve() {
        let list = (1...12).map { "/r/\($0)" }
        let moved = RecentRepositories.inserting("/r/5/", into: list)
        #expect(moved.first == "/r/5/" && moved.count == 12 && !moved.dropFirst().contains("/r/5"))
        let added = RecentRepositories.inserting("/r/new", into: list)
        #expect(added == ["/r/new"] + (1...11).map { "/r/\($0)" })
    }
}
