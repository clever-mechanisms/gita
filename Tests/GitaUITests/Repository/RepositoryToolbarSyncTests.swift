import AppKit
import GitaCore
import Testing

@testable import GitaUI

@MainActor
@Suite("Repository: toolbar declutter & one-click sync", .serialized)
struct RepositoryToolbarSyncTests {
    @Test func defaultItemsDropBranchAndWorkspacesWhileAllowedKeepsThem() {
        let defaults = MainToolbar.defaultItems.map(\.rawValue)
        let allowed = MainToolbar.allowedItems.map(\.rawValue)
        #expect(!defaults.contains(MainToolbar.ID.branch.rawValue))
        #expect(!defaults.contains(MainToolbar.ID.workspaces.rawValue))
        #expect(allowed.contains(MainToolbar.ID.branch.rawValue))
        #expect(allowed.contains(MainToolbar.ID.workspaces.rawValue))
    }

    @Test func repositoryMenuIncludesNewBranchWithShortcut() async throws {
        let fixture = try await RepositoryWindowFixture(prepare: RepositoryWindowFixture.mergedFeature)
        defer { fixture.close() }
        let snapshot = try #require(fixture.model.snapshot)
        let menu = ToolbarMenus.repository(model: fixture.model, snapshot: snapshot, commands: fixture.commands)
        let newBranch = try #require(menu.item(titled: "New Branch…"))
        #expect(newBranch.keyEquivalent == "B")
        #expect(newBranch.keyEquivalentModifierMask == [.command])
    }

    @Test func syncButtonsRenderSymmetricBadgesAndForwardClicks() {
        UITestSupport.bootstrap()
        var clicks: [String] = []
        let fetch = ToolbarSyncButtons.makeButton(
            title: "Fetch", symbol: "arrow.down.to.line", optionsAccessibility: "Fetch options",
            onPrimary: { clicks.append("fetchNow") }, onOptions: { clicks.append("fetchSheet") })
        let pull = ToolbarSyncButtons.makeButton(
            title: "Pull", symbol: "arrow.down", optionsAccessibility: "Pull options",
            onPrimary: { clicks.append("pullNow") }, onOptions: { clicks.append("pullSheet") })
        let push = ToolbarSyncButtons.makeButton(
            title: "Push", symbol: "arrow.up", optionsAccessibility: "Push options",
            onPrimary: { clicks.append("pushNow") }, onOptions: { clicks.append("pushSheet") })

        // Tier 1 dot on Fetch when current upstream moved
        ToolbarSyncButtons.showFetch(
            ToolbarSyncState(movedBranchCount: 1, currentUpstreamMoved: true, fetchToolTip: "origin/main moved"),
            on: fetch)
        #expect(fetch.indicator.mode == .dot)
        #expect(fetch.primaryButton.accessibilityLabel() == "Fetch, upstream moved")
        fetch.frame = NSRect(x: 0, y: 0, width: 120, height: 26)
        fetch.layoutSubtreeIfNeeded()
        UITestSupport.render(fetch)

        // Outlined branch count when multiple branches moved
        ToolbarSyncButtons.showFetch(ToolbarSyncState(movedBranchCount: 3, currentUpstreamMoved: false), on: fetch)
        #expect(fetch.indicator.mode == .outlinedCount(3))
        #expect(fetch.primaryButton.accessibilityLabel() == "Fetch, 3 branches moved")
        fetch.layoutSubtreeIfNeeded()
        UITestSupport.render(fetch)

        // Filled ↓N and ↑N on Pull and Push
        ToolbarSyncButtons.showPull(ToolbarSyncState(behind: 4), on: pull)
        ToolbarSyncButtons.showPush(ToolbarSyncState(ahead: 2), on: push)
        #expect(pull.primaryButton.accessibilityLabel() == "Pull 4 commits")
        #expect(push.primaryButton.accessibilityLabel() == "Push 2 commits")
        UITestSupport.render(pull)
        UITestSupport.render(push)

        // Enabled propagates to child buttons
        fetch.isEnabled = false
        #expect(!fetch.primaryButton.isEnabled && !fetch.chevronButton.isEnabled)
        fetch.isEnabled = true
        #expect(fetch.primaryButton.isEnabled && fetch.chevronButton.isEnabled)

        fetch.primaryButton.onClick?()
        fetch.chevronButton.onClick?()
        pull.primaryButton.onClick?()
        pull.chevronButton.onClick?()
        push.primaryButton.onClick?()
        push.chevronButton.onClick?()
        #expect(clicks == ["fetchNow", "fetchSheet", "pullNow", "pullSheet", "pushNow", "pushSheet"])
    }

    @Test func syncDecisionRoutesPushAndPullSafely() {
        let upstream = ["main": GitBranchUpstream(remote: "origin", branch: "main")]
        let remotes = ["origin": "https://example.invalid/repo.git"]
        #expect(ToolbarSyncDecision.shouldPushNow(branch: "main", upstreams: upstream, remotes: remotes))
        #expect(!ToolbarSyncDecision.shouldPushNow(branch: "topic", upstreams: upstream, remotes: remotes))
        #expect(!ToolbarSyncDecision.shouldPushNow(branch: nil, upstreams: upstream, remotes: remotes))

        // FF-only pull setting runs directly when upstream exists.
        #expect(
            ToolbarSyncDecision.directPullRequest(
                branch: "main", upstreams: upstream, remotes: remotes, preferredMode: .fastForwardOnly, ahead: 2)
                == GitPullRequest(remote: "origin", branch: "main", mode: .fastForwardOnly))
        // Merge/rebase setting with ahead == 0 can safely fast-forward directly.
        #expect(
            ToolbarSyncDecision.directPullRequest(
                branch: "main", upstreams: upstream, remotes: remotes, preferredMode: .merge, ahead: 0)
                == GitPullRequest(remote: "origin", branch: "main", mode: .fastForwardOnly))
        // Merge/rebase setting with ahead > 0 opens PullSheet instead.
        #expect(
            ToolbarSyncDecision.directPullRequest(
                branch: "main", upstreams: upstream, remotes: remotes, preferredMode: .merge, ahead: 1) == nil)
        #expect(
            ToolbarSyncDecision.directPullRequest(
                branch: "topic", upstreams: upstream, remotes: remotes, preferredMode: .fastForwardOnly, ahead: 0)
                == nil)
    }

    @Test func oneClickFetchPullAndPushRunOnFixtureRepository() async throws {
        let remote = try TemporaryRepository()
        try remote.git("config", "receive.denyCurrentBranch", "ignore")
        let repository = try TemporaryRepository()
        let first = try repository.commit("README.md", "one\n", message: "First")
        try repository.git("remote", "add", "origin", remote.url.path)

        let shell = AppShellHarness(arguments: ["Gita", "--repository", repository.url.path])
        await shell.launch(waitingFor: repository.url)
        defer { shell.tearDown() }

        // No upstream yet -> pushOrSheet opens PushSheet.
        shell.app.commands.pushOrSheet()
        await appWaitUntil { shell.alerts.sheets.last?.title == "Push" }
        shell.alerts.answer()
        await appWaitUntil { (try? remote.git("rev-parse", "refs/heads/main"))?.hasPrefix(first) == true }
        await shell.settle()

        // Upstream now exists -> commit & pushOrSheet pushes directly without a sheet.
        let sheetCountBefore = shell.alerts.sheets.count
        let second = try repository.commit("README.md", "two\n", message: "Second")
        shell.app.commands.pushOrSheet()
        await appWaitUntil { (try? remote.git("rev-parse", "refs/heads/main"))?.hasPrefix(second) == true }
        await shell.settle()
        #expect(shell.alerts.sheets.count == sheetCountBefore)

        // Advance remote from another clone, then fetchNow + pullNow run without sheets.
        let other = try TemporaryRepository()
        try other.git("remote", "add", "origin", remote.url.path)
        try other.git("fetch", "origin")
        try other.git("checkout", "-B", "main", "origin/main")
        try other.commit("OTHER.md", "remote\n", message: "Remote commit")
        let remoteTip = try other.git("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
        try other.git("push", "origin", "main")

        shell.app.commands.fetchNow()
        await appWaitUntil {
            (try? repository.git("rev-parse", "refs/remotes/origin/main"))?.hasPrefix(remoteTip) == true
        }
        await shell.settle()

        shell.app.commands.pullNow()
        await appWaitUntil {
            (try? repository.git("rev-parse", "HEAD"))?.hasPrefix(remoteTip) == true
        }
        await shell.settle()
        #expect(shell.alerts.sheets.count == sheetCountBefore)
    }
}
