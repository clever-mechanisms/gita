import AppKit
import Foundation
import GitaCore
import Testing

@testable import GitaUI

/// Fetch, Pull and Push from the Repository menu: each asks in its sheet, then runs on a real temporary repository.
@MainActor
@Suite("App shell sync", .serialized)
struct AppShellSyncTests {
    @Test func withoutARemoteTheCommandsSaySo() async throws {
        let repository = try TemporaryRepository()
        try repository.commit("README.md", "one\n", message: "First")
        let shell = AppShellHarness(arguments: ["Gita", "--repository", repository.url.path])
        await shell.launch(waitingFor: repository.url)
        defer { shell.tearDown() }
        shell.app.commands.fetch()
        await appWaitUntil { shell.app.model.contentBanner != .none }
        #expect(shell.app.model.contentBanner == .info(String(localized: "This repository has no remote.")))
    }

    @Test func pushThenFetchAndPullThroughTheSheets() async throws {
        let remote = try TemporaryRepository()
        try remote.git("config", "receive.denyCurrentBranch", "ignore")
        let repository = try TemporaryRepository()
        let tip = try repository.commit("README.md", "one\n", message: "First")
        try repository.git("remote", "add", "origin", remote.url.path)
        let shell = AppShellHarness(arguments: ["Gita", "--repository", repository.url.path])
        await shell.launch(waitingFor: repository.url)
        defer { shell.tearDown() }

        shell.app.commands.push()
        await appWaitUntil { shell.alerts.sheets.last?.title == "Push" }
        let target = try #require(shell.alerts.sheetViews(NSPopUpButton.self).last)
        #expect(target.titleOfSelectedItem == "origin/main (new)")
        shell.alerts.answer()
        await appWaitUntil { (try? remote.git("rev-parse", "refs/heads/main"))?.hasPrefix(tip) == true }
        await shell.settle()
        #expect(try repository.git("rev-parse", "--abbrev-ref", "main@{upstream}") == "origin/main\n")

        shell.app.commands.fetch()
        await appWaitUntil { shell.alerts.sheets.last?.title == "Fetch" }
        shell.alerts.answer()
        await shell.settle()

        shell.app.commands.pull()
        await appWaitUntil { shell.alerts.sheets.last?.title == "Pull" }
        let pulled = shell.alerts.sheetViews(NSPopUpButton.self).map(\.titleOfSelectedItem)
        // Remote, branch, then how: Settings ▸ Git's Pull mode.
        #expect(Array(pulled.prefix(2)) == ["origin", "main"])
        let mode = GitPullMode(rawValue: Preference.pullMode.string()) ?? .fastForwardOnly
        #expect(pulled.last == mode.localizedTitle)
        shell.alerts.answer(.alertSecondButtonReturn)
    }
}
