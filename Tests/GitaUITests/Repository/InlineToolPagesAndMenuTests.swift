import AppKit
import Foundation
import Testing

@testable import GitaCore
@testable import GitaUI

@MainActor
@Suite("Inline tool pages & top menu bar", .serialized)
struct InlineToolPagesAndMenuTests {
    @Test func mainMenuSplitOrderAndEveryVisibleItemHasIcon() throws {
        UITestSupport.bootstrap()
        let harness = AppShellHarness()
        defer { harness.tearDown() }
        let mainMenu = MainMenu.build(target: harness.app)

        let topTitles = mainMenu.items.map(\.title)
        #expect(
            topTitles == [
                "Gitā",
                String(localized: "File"),
                String(localized: "Edit"),
                String(localized: "View"),
                String(localized: "Repository"),
                String(localized: "Branch"),
                String(localized: "History"),
                String(localized: "Agents"),
                String(localized: "Window"),
            ])

        let iconRequiredMenus = [
            String(localized: "File"),
            String(localized: "View"),
            String(localized: "Repository"),
            String(localized: "Branch"),
            String(localized: "History"),
            String(localized: "Agents"),
            String(localized: "Window"),
        ]
        for menuTitle in iconRequiredMenus {
            let submenu = try #require(mainMenu.item(withTitle: menuTitle)?.submenu)
            let visibleItems = submenu.items.filter { !$0.isSeparatorItem && !$0.isHidden }
            #expect(!visibleItems.isEmpty)
            for item in visibleItems {
                #expect(item.image != nil, "Menu item '\(menuTitle) ▸ \(item.title)' is missing an SF Symbol icon")
            }
        }

        let agentsMenu = try #require(mainMenu.item(withTitle: String(localized: "Agents"))?.submenu)
        let agentActions = agentsMenu.items.filter { !$0.isSeparatorItem }.map(\.action)
        #expect(
            agentActions == [
                #selector(AppDelegate.showAgentsPane),
                #selector(AppDelegate.showCollisionRadar),
                #selector(AppDelegate.showAgentFlightRecorder),
                #selector(AppDelegate.showAgentArena),
            ])

        let windowMenu = try #require(mainMenu.item(withTitle: String(localized: "Window"))?.submenu)
        #expect(windowMenu.items.contains { $0.action == #selector(AppDelegate.showWorkspaceStorage) })
        #expect(
            GitaUI.Section.workspaceSections
                == [.history, .changes, .worktrees, .pullRequests, .deployments, .workflows])
    }

    @Test func sidebarStorageRowSelectsInlineStorageAndWiresCallbacks() async throws {
        let fixture = try await RepositoryWindowFixture()
        defer { fixture.close() }
        #expect(SidebarSelection(page: .storage) == .storage)
        #expect(SidebarSelection.storage.section == .storage)

        let sidebar = fixture.controller.sidebarView
        let storageRow = try #require(
            sidebar.rows.firstIndex {
                if case .nav(let nav) = $0 { nav.target == .page(.storage) } else { false }
            })
        sidebar.activate(storageRow, fromKeyboard: false)

        #expect(fixture.model.section == .storage)
        #expect(fixture.controller.toolHost.activeController is StorageInlineViewController)
        #expect(!fixture.controller.toolHost.container.isHidden)
        #expect(fixture.controller.prWorkspace.isHidden)
        let refreshedStorageRow = try #require(
            sidebar.rows.first {
                if case .nav(let nav) = $0 { nav.target == .page(.storage) } else { false }
            })
        if case .nav(let nav) = refreshedStorageRow {
            #expect(nav.selected)
        } else {
            Issue.record("Expected storage nav row")
        }

        fixture.controller.openToolPage(.storage(scope: .health))
        let storageVC = try #require(fixture.controller.toolHost.activeController as? StorageInlineViewController)
        #expect(storageVC.scope == .health)
    }

    @Test func inlineToolPagesMountReturnToPreviousSectionAndDetachCleanly() async throws {
        let fixture = try await RepositoryWindowFixture()
        defer { fixture.close() }
        let controller = fixture.controller

        fixture.model.section = .changes
        controller.openToolPage(.cleanup)
        let cleanup = try #require(controller.toolHost.activeController as? CleanupAssistantViewController)
        #expect(controller.model.section == .cleanup)
        cleanup.onBack?()
        #expect(controller.model.section == .changes)
        #expect(controller.toolHost.activeController == nil)
        #expect(controller.toolHost.container.isHidden)

        let range = LineRangeSpec(path: "README.md", startLine: 1, endLine: 1)
        let requests: [(ToolPageRequest, NSViewController.Type)] = [
            (.stackedBranches(baseBranch: "main"), BranchStackViewController.self),
            (.submodulesLFS(initialTab: .lfs), SubmodulesLFSViewController.self),
            (.reflog(ref: "HEAD"), ReflogViewController.self),
            (.codeSearch(initialPattern: "hello", pathFilter: nil), CodeSearchViewController.self),
            (.lineHistory(range: range), LineHistoryViewController.self),
            (.commitBuckets, CommitBucketsViewController.self),
            (.collisionRadar, CollisionRadarViewController.self),
            (.flightRecorder, AgentFlightRecorderViewController.self),
            (.agentArena(baseCommit: "HEAD"), AgentArenaViewController.self),
        ]
        for (request, expectedType) in requests {
            controller.openToolPage(request)
            #expect(controller.model.section == request.section)
            let active = try #require(controller.toolHost.activeController)
            #expect(type(of: active) == expectedType)
        }

        let url = try #require(URL(string: "https://example.test"))
        let pair = VisualPreviewPair(productionURL: url, previewURL: url, title: "Preview")
        controller.openToolPage(.visualPreviewDiff(pair: pair))
        let preview = try #require(controller.toolHost.activeController as? VisualPreviewDiffViewController)
        preview.onBack?()
        #expect(controller.model.section == .deployments)
        #expect(controller.toolHost.activeController == nil)
    }

    @Test func toolPagesRepositoryChangedKeepsSameRepoAndExitsWhenServiceChanges() async throws {
        let fixture = try await RepositoryWindowFixture()
        defer { fixture.close() }
        let controller = fixture.controller

        // Same repo refresh preserves the mounted tool controller.
        controller.openToolPage(.reflog(ref: "HEAD"))
        let originalReflog = try #require(controller.toolHost.activeController as? ReflogViewController)
        controller.toolPagesRepositoryChanged()
        #expect(controller.toolHost.activeController === originalReflog)

        // Replacing the underlying GitService unmounts the stale tool and exits back to History.
        fixture.model.service = GitService(root: fixture.repository.url)
        controller.toolPagesRepositoryChanged()
        #expect(controller.toolHost.activeController == nil)
        #expect(controller.model.section == .history)
    }
}
