import Foundation
import Testing

@testable import GitaCore

/// Further history pages read from one running `git log`: the same pages `--skip` gives, one process per run of
/// consecutive pages.
struct HistoryStreamTests {
    @Test func recordsEndAtTheirSeventhNul() {
        let record = Data("a\0b\0c\0d\0e\0f\0g\0".utf8)
        let two = record + record + Data("partial\0".utf8)
        #expect(HistoryStream.scan(two, from: 0, counted: 0, to: 7).end == record.count)
        #expect(HistoryStream.scan(two, from: 0, counted: 0, to: 14).end == record.count * 2)
        let short = HistoryStream.scan(two, from: 0, counted: 0, to: 21)
        #expect(short.end == nil)
        #expect(short.scanned == two.count && short.nuls == 15)
        // Counting goes on where it stopped.
        let more = two + record
        #expect(HistoryStream.scan(more, from: short.scanned, counted: short.nuls, to: 21).end != nil)
    }

    @Test func pagesContinueOneWalk() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitaStream-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = CommandRunner()
        @discardableResult
        func git(_ arguments: [String]) async throws -> String {
            let result = try await runner.run(
                executable: "git",
                arguments: ["-c", "user.name=T", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"]
                    + arguments,
                directory: root, timeout: 20, outputLimit: 1 << 20)
            #expect(result.exitCode == 0, "\(arguments)")
            return result.text
        }
        try await git(["init", "--initial-branch=main", "--template="])
        for index in 0..<25 { try await git(["commit", "--allow-empty", "-m", "main \(index)"]) }
        try await git(["switch", "-c", "side", "HEAD~10"])
        for index in 0..<8 { try await git(["commit", "--allow-empty", "-m", "side \(index)"]) }
        try await git(["switch", "main"])
        func expected(_ skip: Int, _ count: Int) async throws -> [String] {
            try await git(["log", "--topo-order", "--format=%H", "--all", "--skip=\(skip)", "--max-count=\(count)"])
                .split(separator: "\n").map(String.init)
        }
        let service = GitService(root: root)
        _ = try await service.snapshot(limit: 10)

        #expect(try await service.history(limit: 10, skip: 10).map(\.id) == expected(10, 10))
        let first = try #require(await service.historyStream)
        #expect(try await service.history(limit: 10, skip: 20).map(\.id) == expected(20, 10))
        #expect(await service.historyStream === first)
        // One commit read ahead (to learn whether more follow) and asked for again: still the same walk.
        #expect(try await service.history(limit: 3, skip: 29).map(\.id) == expected(29, 3))
        #expect(await service.historyStream === first)
        // A page read entirely from the last one leaves that page whole for the next.
        #expect(try await service.history(limit: 1, skip: 29).map(\.id) == expected(29, 1))
        #expect(try await service.history(limit: 2, skip: 31).map(\.id) == expected(31, 2))
        #expect(await service.historyStream === first)
        // Elsewhere in the history: a walk of its own, from there.
        #expect(try await service.history(limit: 4, skip: 5).map(\.id) == expected(5, 4))
        #expect(await service.historyStream !== first)
        // The end of the history ends the walk.
        #expect(try await service.history(limit: 50, skip: 9).map(\.id) == expected(9, 50))
        #expect(await service.historyStream == nil)

        // An unread walk is closed once idle.
        _ = try await service.history(limit: 5, skip: 10)
        let idle = try #require(await service.historyStream)
        await service.closeIdleStream(idle)
        #expect(await service.historyStream === idle)
        await service.closeIdleStream(idle, now: .now + .seconds(61))
        #expect(await service.historyStream == nil)

        // The references moved: the next snapshot's history is walked again.
        _ = try await service.history(limit: 5, skip: 10)
        try await git(["commit", "--allow-empty", "-m", "newer"])
        _ = try await service.snapshot(limit: 10)
        #expect(await service.historyStream == nil)
        #expect(try await service.history(limit: 10, skip: 10).map(\.id) == expected(10, 10))
    }
}
