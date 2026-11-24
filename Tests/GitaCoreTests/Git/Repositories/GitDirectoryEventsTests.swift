import Foundation
import Testing

@testable import GitaCore

@Suite("Git folder events that can change a checkout's view")
struct GitDirectoryEventsTests {
    static let common = "/repo/.git"

    @Test func theMainCheckoutIgnoresOtherWorktreesIndexesAndReflogs() {
        let events = GitDirectoryEvents(
            gitDirectory: URL(fileURLWithPath: Self.common), commonDirectory: URL(fileURLWithPath: Self.common))
        for path in [
            "/repo/.git/worktrees/agent/index", "/repo/.git/worktrees/agent/index.lock",
            "/repo/.git/worktrees/agent/logs/HEAD", "/repo/.git/worktrees/agent/FETCH_HEAD",
            "/repo/.git/worktrees/agent/rebase-merge/done", "/repo/.git/logs/HEAD", "/repo/.git/logs/refs/heads/main",
        ] {
            #expect(!events.matters(path), "\(path)")
        }
        for path in [
            "/repo/.git/index", "/repo/.git/HEAD", "/repo/.git/refs/heads/main", "/repo/.git/packed-refs",
            "/repo/.git/worktrees/agent/HEAD", "/repo/.git/worktrees/agent/locked", "/repo/.git/worktrees/agent",
            "/repo/.git/worktrees/agent/", "/repo/.git/worktrees", "/repo/.git/MERGE_HEAD", "/repo/.git",
            "/repo/src/file.swift", "/elsewhere/file",
        ] {
            #expect(events.matters(path), "\(path)")
        }
    }

    @Test func aLinkedWorktreeWatchesItsOwnFolderButNotTheMainIndex() {
        let events = GitDirectoryEvents(
            gitDirectory: URL(fileURLWithPath: Self.common + "/worktrees/mine"),
            commonDirectory: URL(fileURLWithPath: Self.common))
        #expect(events.matters("/repo/.git/worktrees/mine/index"))
        #expect(events.matters("/repo/.git/worktrees/mine/HEAD"))
        #expect(events.matters("/repo/.git/worktrees/mine/rebase-merge/done"))
        #expect(!events.matters("/repo/.git/worktrees/mine/logs/HEAD"))
        #expect(!events.matters("/repo/.git/worktrees/other/index"))
        #expect(events.matters("/repo/.git/worktrees/other/HEAD"))
        #expect(!events.matters("/repo/.git/index"))
        #expect(!events.matters("/repo/.git/index.lock"))
        #expect(events.matters("/repo/.git/HEAD"))
        #expect(events.matters("/repo/.git/refs/heads/feature"))
    }
}
