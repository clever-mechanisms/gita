import AppKit
import GitaCore
import Testing

@testable import GitaUI

/// The branch menu: checking out a remote branch names the local one when they meet, and offers to advance it
/// when they don't.
@MainActor
@Suite struct ReferenceMenuCheckoutTests {
    private func reference(
        _ name: String, _ fullName: String, _ commit: String, _ kind: GitReference.Kind, current: Bool = false
    ) -> GitReference {
        GitReference(name: name, fullName: fullName, commit: commit, kind: kind, isCurrent: current)
    }

    private func builder(
        _ references: [GitReference], commands: RecordingCommands, remoteURLs: [String: String] = [:]
    ) -> ReferenceMenuBuilder {
        var snapshot = RepositorySnapshot(
            root: URL(fileURLWithPath: "/repo"), branch: "feature", head: "h", changes: [], commits: [],
            references: references, worktrees: [GitWorktree(path: "/repo", branch: "feature", head: "h")],
            stashes: [], remoteURL: nil, gitDirectory: URL(fileURLWithPath: "/repo/.git"))
        snapshot.remoteURLs = remoteURLs
        return ReferenceMenuBuilder(
            snapshot: snapshot, canOperate: true, isMutating: false, filters: BranchFilters(), vercel: nil,
            productionBranch: nil, commits: [], commands: commands, target: nil,
            actions: ReferenceMenuActions(
                worktreeItems: { _ in [] }, reviewReference: { _ in nil }, reviewCommit: { _ in nil },
                toggleFilter: { _, _ in }, clearFilters: {}, openRemoteBranch: { _ in }))
    }

    private func itemTitles(_ menu: NSMenu) -> [String] { menu.items.map(\.title) }

    @Test func aRemoteBranchCanAdvanceItsLocalBranch() {
        UITestSupport.bootstrap()
        let commands = RecordingCommands()
        let refs = [
            reference("main", "refs/heads/main", "old", .branch),
            reference("origin/main", "refs/remotes/origin/main", "new", .remote),
            reference("feature", "refs/heads/feature", "h", .branch, current: true),
        ]
        let menu = builder(refs, commands: commands).menu(refs[1])
        #expect(itemTitles(menu).contains("Check Out"))
        #expect(itemTitles(menu).contains("Advance “main” to Here"))
        menu.items.first { $0.title == "Advance “main” to Here" }?.perform()
        #expect(commands.calls == ["advanceLocalBranch refs/remotes/origin/main"])
    }

    @Test func checkoutOfARemoteAtTheLocalCommitNamesTheLocalBranch() {
        UITestSupport.bootstrap()
        let commands = RecordingCommands()
        let refs = [
            reference("main", "refs/heads/main", "same", .branch),
            reference("origin/main", "refs/remotes/origin/main", "same", .remote),
        ]
        let menu = builder(refs, commands: commands).menu(refs[1])
        #expect(itemTitles(menu).contains("Check Out “main”"))
        #expect(!itemTitles(menu).contains { $0.hasPrefix("Advance") })
        menu.items.first { $0.title == "Check Out “main”" }?.perform()
        #expect(commands.calls == ["checkoutReference refs/remotes/origin/main"])
    }

    @Test func aRemoteAlreadyCheckedOutLocallyOffersNoSwitch() {
        let commands = RecordingCommands()
        let refs = [
            reference("main", "refs/heads/main", "same", .branch, current: true),
            reference("origin/main", "refs/remotes/origin/main", "same", .remote),
        ]
        let titles = itemTitles(builder(refs, commands: commands).menu(refs[1]))
        #expect(!titles.contains { $0.hasPrefix("Check Out") || $0.hasPrefix("Advance") })
    }

    @Test func tagMenuOffersPushAndRemoteDeleteWhenRemotesExist() throws {
        UITestSupport.bootstrap()
        let tag = reference("0.1.0", "refs/tags/0.1.0", "h", .tag)
        let commands = RecordingCommands()

        let noRemoteTitles = itemTitles(builder([tag], commands: commands).menu(tag))
        #expect(!noRemoteTitles.contains { $0.hasPrefix("Push to") || $0.hasPrefix("Delete from") })

        let oneRemoteMenu = builder([tag], commands: commands, remoteURLs: ["sqligrp": "git@github.com:o/r.git"])
            .menu(tag)
        try #require(oneRemoteMenu.items.first { $0.title == "Push to “sqligrp”" }).perform()
        try #require(oneRemoteMenu.items.first { $0.title == "Delete from “sqligrp”…" }).perform()
        #expect(commands.calls == ["pushTag 0.1.0 sqligrp", "deleteRemoteTag 0.1.0 sqligrp"])

        commands.calls = []
        let multiMenu = builder(
            [tag], commands: commands,
            remoteURLs: ["origin": "git@github.com:o/r.git", "sqligrp": "git@github.com:s/r.git"]
        ).menu(tag)
        let pushMenu = try #require(multiMenu.items.first { $0.title == "Push to" }?.submenu)
        try #require(pushMenu.items.first { $0.title == "sqligrp" }).perform()
        try #require(pushMenu.items.first { $0.title == "All Remotes" }).perform()
        let deleteMenu = try #require(multiMenu.items.first { $0.title == "Delete from Remote" }?.submenu)
        try #require(deleteMenu.items.first { $0.title == "origin" }).perform()
        #expect(commands.calls == ["pushTag 0.1.0 sqligrp", "pushTag 0.1.0 all", "deleteRemoteTag 0.1.0 origin"])
    }
}
