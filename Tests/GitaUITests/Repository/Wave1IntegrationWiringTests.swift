import AppKit
import Foundation
import GitaCore
import Testing

@testable import GitaUI

/// Verifies Wave 1 cross-builder wiring: W1-D `RemoteMonitor` / `RemoteDelta` feeding W1-A toolbar & strip,
/// W1-C sidebar moved badges, W1-F live Settings status hooks, and W1-B/W1-E CodePane / Detail hunk & editor wiring.
@MainActor
@Suite("Wave 1 cross-builder integration wiring", .serialized)
struct Wave1IntegrationWiringTests {
    @Test func remoteDeltaDrivesToolbarSyncStripAndSidebarMovedIndicators() async throws {
        let remote = try TemporaryRepository()
        try remote.git("config", "receive.denyCurrentBranch", "ignore")
        let fixture = try await RepositoryWindowFixture { repo in
            try repo.commit("README.md", "v1\n", message: "Initial")
            try repo.git("remote", "add", "origin", remote.url.path)
            try repo.git("push", "-u", "origin", "main")
        }
        defer { fixture.close() }
        let repo = fixture.repository

        // Advance remote from another clone so ls-remote sees origin/main moved without fetching.
        let other = try TemporaryRepository()
        try other.git("remote", "add", "origin", remote.url.path)
        try other.git("fetch", "origin")
        try other.git("checkout", "-B", "main", "origin/main")
        try other.commit("OTHER.md", "v2\n", message: "Remote update")
        try other.git("push", "origin", "main")

        RemoteMonitor.shared.checkNow(for: repo.url, allowAutoFetch: false)
        try await fixture.wait("remote delta detected") {
            fixture.model.remoteDelta?.currentUpstreamMoved == true
        }

        // Wiring 1: Toolbar sync state & WorktreeStripPresenter read model.remoteDelta / remoteCheckStatusSummary.
        let sync = MainToolbar.syncState(for: fixture.model)
        #expect(sync.movedBranchCount == 1)
        #expect(sync.currentUpstreamMoved)
        #expect(sync.fetchToolTip?.contains("origin/main") == true)

        let snapshot = try #require(fixture.model.snapshot)
        let presenter = WorktreeStripPresenter(
            snapshot: snapshot, sessions: [], signals: ProviderSignalQuery(signals: []), checks: [],
            remoteDelta: fixture.model.remoteDelta, remoteCheckStatusSummary: fixture.model.remoteCheckStatusSummary)
        let remoteHint = try #require(presenter.input.remoteUpdate)
        #expect(remoteHint.summary.contains("origin/main moved"))

        fixture.controller.refreshStrip()
        #expect(fixture.controller.strip.mode.chips.contains { $0.click == StripCellContent.Click.fetch })
        #expect(fixture.controller.strip.heightConstraint.constant == WorktreeStripView.compactHeight)

        // Wiring 2: RemoteMonitor.movedKeys feeds SidebarRepositoryList & sidebar rows.
        let moved = RemoteMonitor.shared.movedKeys { WindowAgents.key($0) }
        let repoKey = try #require(WindowAgents.key(repo.url))
        #expect(moved.roots.contains(repoKey))
        #expect(moved.checkouts.contains(repoKey))
        fixture.controller.rebuildSidebar()
        let sidebarRepos: [RepositorySidebarView.Repository] = fixture.controller.sidebarView.repositoriesPane.rows
            .compactMap { row in
                if case .repository(let value, _) = row { return value }
                return nil
            }
        #expect(sidebarRepos.first { WindowAgents.key($0.root) == repoKey }?.remoteMoved == true)
    }

    @Test func appDelegateSettingsHooksReportLiveRemoteMonitorStatus() async throws {
        let remote = try TemporaryRepository()
        let repo = try TemporaryRepository()
        try repo.commit("README.md", "v1\n", message: "Initial")
        try repo.git("remote", "add", "origin", remote.url.path)

        let shell = AppShellHarness(arguments: ["Gita", "--repository", repo.url.path])
        await shell.launch(waitingFor: repo.url)
        defer { shell.tearDown() }

        let hooks = SettingsAppHooks(shell: shell.app)
        let status = hooks.remoteUpdatesStatus()
        #expect(status.contains(repo.url.lastPathComponent))
        #expect(!status.isEmpty)
    }

    @Test func detailWiresOpenInEditorAndHunkCallbacks() async throws {
        let fixture = try await RepositoryWindowFixture()
        defer { fixture.close() }
        try fixture.repository.write("Sources/app.swift", "let answer = 43\n")
        try await fixture.refresh()
        fixture.model.section = .changes
        try await fixture.wait("diff loaded") {
            fixture.controller.codePane.diffView.document?.hunks.count == 1
        }
        #expect(fixture.controller.codePane.onApplyHunkAtIndex != nil)
        #expect(fixture.controller.codePane.onDiscardHunk != nil)
        #expect(fixture.controller.codePane.onOpenInEditor != nil)
        let editorApp = URL(fileURLWithPath: "/Applications/TestEditor.app")
        var openedFiles: [URL] = []
        let recorder = AppOpener(
            locate: { _ in editorApp },
            open: { urls, _, _ in openedFiles.append(contentsOf: urls) },
            openApplication: { _, _ in },
            reveal: { _ in },
            openBuiltInTerminal: { _, _ in })
        fixture.controller.openInEditor(at: nil, opener: recorder)
        #expect(openedFiles.map(\.lastPathComponent) == ["app.swift"])
    }
}
