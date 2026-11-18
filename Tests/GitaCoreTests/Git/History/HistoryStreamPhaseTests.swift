import Foundation
import Testing

@testable import GitaCore

/// A history stream's phases, driven by a shell standing in for `git log`.
@Suite struct HistoryStreamPhaseTests {
    /// One `GitArguments.commitFormat` record.
    private static let record =
        #"printf '"# + String(repeating: "a", count: 40)
        + #"\000\000A\000a@example.com\0000\000\000Subject\000'"#

    private func stream(_ script: String) throws -> HistoryStream {
        try HistoryStream(
            CommandRequest(executable: "/bin/sh", arguments: ["-c", script]),
            snapshot: key, scope: .all, position: 0)
    }

    private var key: HistoryKey {
        HistoryKey(head: nil, references: Data(), limit: 0, ancestryMetadata: "", scope: .all)
    }

    @Test func aWalkThatGoesOnKeepsStreamingUntilClosed() async throws {
        let walk = try stream(Self.record + "; " + Self.record + "; sleep 30")
        #expect(try await walk.page(1, at: 0).count == 1)
        #expect(walk.phase == .streaming)
        #expect(walk.continues(key, scope: .all, at: 1))
        walk.close()
        #expect(walk.phase == .closed)
        #expect(!walk.continues(key, scope: .all, at: 1))
    }

    @Test func theEndOfTheHistoryEndsTheWalk() async throws {
        let walk = try stream(Self.record)
        #expect(try await walk.page(5, at: 0).count == 1)
        #expect(walk.phase == .exited)
        #expect(!walk.continues(key, scope: .all, at: 1))
    }

    @Test func aGitThatFailsAfterItsOutputFailsThePage() async throws {
        let walk = try stream(Self.record + "; echo 'fatal: bad object' >&2; exit 3")
        await #expect(throws: GitError.self) { try await walk.page(5, at: 0) }
        #expect(walk.phase == .exited)
    }

    /// Output ended but Git did not exit within the grace period, nor on SIGTERM: it is killed, and the walk is not
    /// known whole.
    @Test func aGitKilledAfterItsOutputFailsThePage() async throws {
        let walk = try stream(Self.record + "; exec 1>&-; trap '' TERM; sleep 30")
        await #expect(throws: GitError.self) { try await walk.page(5, at: 0) }
        #expect(walk.phase == .exited)
    }
}
