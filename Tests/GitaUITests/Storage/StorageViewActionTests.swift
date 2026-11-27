import AppKit
import Testing

@testable import GitaCore
@testable import GitaUI

@MainActor
struct StorageViewActionTests {
    @Test func healthBannersShowTheActionMessageAndStatusColor() throws {
        UITestSupport.bootstrap()
        #expect(StorageStyle.banner(.idle) == nil)
        let states: [(HealthActionState, NSColor)] = [
            (.running("Working"), Theme.running), (.succeeded("Done"), Theme.success),
            (.failed("Failed"), Theme.failure),
        ]
        for ((state, color), message) in zip(states, ["Working", "Done", "Failed"]) {
            let banner = try #require(StorageStyle.banner(state))
            let label = try #require(SharedFixtures.descendants(banner, of: NSTextField.self).first)
            #expect(label.stringValue == message && label.textColor == color)
        }
    }

    @Test func healthCardsReflectStateAndDispatchTheirActions() throws {
        UITestSupport.bootstrap()
        let recommend = StorageHealthAction.enableRecommended(
            fsMonitor: true, untrackedCache: false, commitGraph: true, registerMaintenance: false)
        let summary = StorageHealthSummaryModel(
            enabledCount: 2, totalCount: 4, headline: "2 of 4 optimizations enabled",
            subtitle: "Enable recommended optimizations.", status: .recommend(recommend))
        let cards: [StorageHealthCardModel] = [
            .init(
                section: .performance, symbol: "hare.fill", iconTone: .green,
                title: "Cache", statusText: "Enabled", statusTone: .positive,
                detail: "Details", action: .untrackedCache(false), control: .toggle(true), enabled: true),
            .init(
                section: .performance, symbol: "point.3.connected.trianglepath.dotted", iconTone: .purple,
                title: "Graph", statusText: "Not built", statusTone: .neutral,
                detail: "Rebuild", action: .commitGraph, control: .button, buttonSymbol: "arrow.clockwise",
                enabled: true),
            .init(
                section: .maintenance, symbol: "clock.arrow.2.circlepath", iconTone: .indigo,
                title: "Busy", statusText: "Unregistered", statusTone: .neutral,
                detail: "Running", action: .maintenance, control: .button, buttonSymbol: "play.fill",
                secondaryToggle: .init(
                    isOn: false, action: .maintenanceRegistration(true), accessibilityLabel: "Register"),
                enabled: false),
        ]
        var actions: [StorageHealthAction] = []
        var openedGlobalSettings = 0
        let view = StorageHealthView(
            summary: summary, cards: cards, actionState: .succeeded("Saved"),
            openGlobalSettings: { openedGlobalSettings += 1 },
            perform: { actions.append($0) })
        view.frame = NSRect(x: 0, y: 0, width: 880, height: 560)
        UITestSupport.render(view)
        let toggles = SharedFixtures.descendants(view, of: AccentSwitch.self)
        let cacheToggle = try #require(toggles.first)
        #expect(cacheToggle.isOn)
        #expect(cacheToggle.accessibilityPerformPress())
        let buttons = SharedFixtures.descendants(view, of: PartsButton.self)
        let globalButton = try #require(
            buttons.first { $0.accessibilityLabel() == String(localized: "Global Defaults…") })
        #expect(globalButton.accessibilityPerformPress())
        #expect(openedGlobalSettings == 1)
        let enableAll = try #require(buttons.first { $0.accessibilityLabel() == recommend.title })
        #expect(enableAll.accessibilityPerformPress())
        let rebuild = try #require(buttons.first { $0.accessibilityLabel() == StorageHealthAction.commitGraph.title })
        #expect(rebuild.accessibilityPerformPress())
        let runNow = buttons.first { $0.accessibilityLabel() == StorageHealthAction.maintenance.title }
        #expect(runNow?.isEnabled == false)
        #expect(actions == [.untrackedCache(false), recommend, .commitGraph])
    }

    @Test func summaryBarAndWorkspaceListRenderAndDispatchActions() throws {
        UITestSupport.bootstrap()
        let root = URL(fileURLWithPath: "/tmp/storage-summary-test")
        let report = StoragePresentationFixture.report(root)
        var refreshed = 0
        var trashed = 0
        let summary = StorageSummaryBar(report: report, refresh: { refreshed += 1 }, trash: { trashed += 1 })
        summary.frame = NSRect(x: 0, y: 0, width: 840, height: 140)
        summary.updateSelection([])
        summary.updateSelection([root.path + "/linked/node_modules"])
        UITestSupport.render(summary)
        let buttons = SharedFixtures.descendants(summary, of: PartsButton.self)
        let refreshButton = try #require(buttons.first { $0.accessibilityLabel() == String(localized: "Refresh") })
        #expect(refreshButton.accessibilityPerformPress())
        #expect(refreshed == 1)

        var inspected: URL?
        let rows = StoragePresenter().workspaceRows(for: [report])
        let workspace = StorageWorkspaceListView(
            state: .loaded(rows: rows, failureMessage: nil), refresh: { refreshed += 1 }, inspect: { inspected = $0 })
        workspace.frame = NSRect(x: 0, y: 0, width: 840, height: 480)
        UITestSupport.render(workspace)
        let controls = SharedFixtures.descendants(workspace, of: NSControl.self)
        let rowControl = try #require(
            controls.first { $0.accessibilityLabel()?.contains(report.repositoryName) == true })
        #expect(rowControl.accessibilityPerformPress())
        #expect(inspected == report.mainRoot)
    }

    @Test func outlineMenuOffersOnlyActionsAllowedForItsRow() throws {
        UITestSupport.bootstrap()
        let view = StorageOutlineView(frame: .zero)
        let outline = try #require(view.documentView as? NSOutlineView)
        let report = StoragePresentationFixture.report(URL(filePath: "/tmp/storage-menu"))
        let nodes = StoragePresenter().outlineNodes(
            for: report, activeAgentPaths: [], now: StoragePresentationFixture.now)
        view.display(nodes)
        let menu = NSMenu()
        view.menuNeedsUpdate(menu)
        #expect(menu.items.isEmpty)
        var removed: CheckoutStorageReport?
        var trashed: HeavyFolderEntry?
        view.onRemove = { removed = $0 }
        view.onTrash = { trashed = $0 }
        func select(_ node: StorageOutlineNode, item: Any) throws {
            let row = outline.row(forItem: item)
            try #require(row >= 0)
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            view.menuNeedsUpdate(menu)
            #expect(menu.items.first?.title == "Reveal in Finder")
            if node.checkout?.path == report.mainRoot.appendingPathComponent("linked") {
                try perform("Remove Worktree…")
                #expect(removed == node.checkout)
            } else {
                #expect(menu.item(withTitle: "Remove Worktree…") == nil)
            }
            if node.isSelectable {
                try perform("Move to Trash…")
                #expect(trashed == node.entry)
            } else {
                #expect(menu.item(withTitle: "Move to Trash…") == nil)
            }
        }
        func perform(_ title: String) throws {
            let index = menu.indexOfItem(withTitle: title)
            try #require(index >= 0)
            menu.performActionForItem(at: index)
        }
        for (index, node) in nodes.enumerated() {
            let item = view.outlineView(outline, child: index, ofItem: nil)
            try select(node, item: item)
            outline.expandItem(item)
            for (childIndex, child) in node.children.enumerated() {
                try select(child, item: view.outlineView(outline, child: childIndex, ofItem: item))
            }
        }
        #expect(removed?.path.lastPathComponent == "linked")
        #expect(trashed?.relativePath == "node_modules")
    }

    @Test func windowControllerRendersAllScopesInLightAndDark() async throws {
        UITestSupport.bootstrap()
        let root = URL(fileURLWithPath: "/tmp/bambu-bar-website")
        let otherRoot = URL(fileURLWithPath: "/tmp/gita-app")
        let report = Self.realisticReport(root: root)
        let otherReport = Self.realisticReport(root: otherRoot)
        let snapshot = RepositoryHealthSnapshot(
            worktreePaths: report.checkouts.map(\.id),
            fsMonitor: .disabled,
            untrackedCache: .enabled,
            commitGraph: CommitGraphInfo(
                path: root.appendingPathComponent(".git/objects/info/commit-graph"),
                modifiedAt: Date(timeIntervalSinceNow: -3_600)),
            maintenance: GitMaintenanceInfo(
                automatic: .unset, isRegistered: false,
                looseObjects: 293, packedObjects: 6_322, packs: 2, looseKiB: 1_200, packedKiB: 35_560))

        let store = StorageStore(scan: { url, _ in url == otherRoot ? otherReport : report })
        await store.scanRepository(root)?.value
        await store.scanWorkspace([root, otherRoot]).value
        store.healthStates[store.canonicalPath(root)] = .loaded(snapshot)

        let controller = StorageWindowController(store: store)
        var openedGlobal = 0
        controller.onOpenGlobalSettings = { openedGlobal += 1 }
        let window = try #require(controller.window)
        window.setContentSize(NSSize(width: 920, height: 640))
        let contentView = try #require(window.contentView)
        let ctx = StorageWindowContext(
            repositoryRoot: root, knownRepositories: [root, otherRoot],
            activeAgentPaths: [root.deletingLastPathComponent().appendingPathComponent("madtom").path])
        let dir = ProcessInfo.processInfo.environment["GITA_SNAPSHOT_DIR"]

        // Global Workspace Storage window (All Repositories)
        controller.show(context: ctx)
        window.orderOut(nil)
        await store.scanWorkspace([root, otherRoot]).value
        store.notify()
        let globalButton = try #require(
            SharedFixtures.descendants(contentView, of: PartsButton.self)
                .first { $0.accessibilityIdentifier() == "storage.workspace.globalDefaults" })
        #expect(globalButton.accessibilityPerformPress() && openedGlobal == 1)
        try Self.captureBothModes(window, contentView, prefix: "storage-workspace", in: dir)

        // Inline per-repo Storage & Health scopes (Disk Usage + Health & Maintenance)
        let inline = StorageInlineViewController(store: store)
        let inlineWindow = UITestSupport.host(inline, size: NSSize(width: 920, height: 640))
        defer { inlineWindow.close() }
        inline.configure(context: ctx, scope: .repository)
        inline.view.layoutSubtreeIfNeeded()
        if let checkbox = SharedFixtures.descendants(inline.view, of: NSButton.self)
            .first(where: { $0.identifier?.rawValue == root.appendingPathComponent("node_modules").path })
        {
            checkbox.performClick(nil)
        }
        try Self.captureBothModes(inlineWindow, inline.view, prefix: "storage-repo", in: dir)

        inline.configure(context: ctx, scope: .health)
        store.healthStates[store.canonicalPath(root)] = .loaded(snapshot)
        store.notify()
        try Self.captureBothModes(inlineWindow, inline.view, prefix: "storage-health", in: dir)
    }

    @Test func inlineViewControllerRendersDiskUsageAndHealthAndWiresCallbacks() async throws {
        UITestSupport.bootstrap()
        let root = URL(fileURLWithPath: "/tmp/inline-storage-repo")
        let report = Self.realisticReport(root: root)
        let snapshot = RepositoryHealthSnapshot(
            worktreePaths: report.checkouts.map(\.id),
            fsMonitor: .enabled,
            untrackedCache: .enabled,
            commitGraph: CommitGraphInfo(path: nil, modifiedAt: nil),
            maintenance: GitMaintenanceInfo(
                automatic: .unset, isRegistered: false,
                looseObjects: 42, packedObjects: 100, packs: 1, looseKiB: 80, packedKiB: 120),
            fsMonitorScope: .global,
            untrackedCacheScope: .local)
        let store = StorageStore(scan: { _, _ in report })
        await store.scanRepository(root)?.value
        store.healthStates[store.canonicalPath(root)] = .loaded(snapshot)

        let controller = StorageInlineViewController(store: store)
        var openedWorkspace = 0
        var openedGlobal = 0
        controller.onOpenWorkspaceStorage = { openedWorkspace += 1 }
        controller.onOpenGlobalSettings = { openedGlobal += 1 }

        let ctx = StorageWindowContext(repositoryRoot: root, knownRepositories: [root])
        controller.configure(context: ctx, scope: .repository)
        controller.view.frame = NSRect(x: 0, y: 0, width: 880, height: 560)
        UITestSupport.render(controller.view)

        let repoButtons = SharedFixtures.descendants(controller.view, of: PartsButton.self)
        let allRepos = try #require(
            repoButtons.first { $0.accessibilityIdentifier() == "storage.inline.allRepositories" })
        #expect(allRepos.accessibilityPerformPress())
        #expect(openedWorkspace == 1)

        controller.configure(context: ctx, scope: .health)
        store.healthStates[store.canonicalPath(root)] = .loaded(snapshot)
        store.notify()
        UITestSupport.render(controller.view)

        let labels = SharedFixtures.descendants(controller.view, of: NSTextField.self).map(\.stringValue)
        #expect(labels.contains(String(localized: "Inherited from global")))
        #expect(labels.contains(String(localized: "This repo")))
        #expect(labels.contains(String(localized: "This repo (.git/config)")))
        let healthButtons = SharedFixtures.descendants(controller.view, of: PartsButton.self)
        let globalButton = try #require(
            healthButtons.first { $0.accessibilityLabel() == String(localized: "Global Defaults…") })
        #expect(globalButton.accessibilityPerformPress())
        #expect(openedGlobal == 1)

        controller.cancel()
    }

    private static func captureBothModes(
        _ window: NSWindow, _ view: NSView, prefix: String, in directory: String?
    ) throws {
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            let app = try #require(NSAppearance(named: appearance))
            window.appearance = app
            view.appearance = app
            app.performAsCurrentDrawingAppearance {
                view.layoutSubtreeIfNeeded()
                let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
                #expect(rep != nil)
                if let rep {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    if let directory, let png = rep.representation(using: .png, properties: [:]) {
                        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(prefix)-\(name).png")
                        try? png.write(to: url)
                    }
                }
            }
        }
    }

    private static func realisticReport(root: URL) -> RepositoryStorageReport {
        let now = Date()
        let parent = root.deletingLastPathComponent()
        let git = GitStoreBreakdown(
            gitCommonDirectory: root.appendingPathComponent(".git"),
            totalAllocatedBytes: 37_400_000, totalLogicalBytes: 37_400_000,
            objectsAllocatedBytes: 34_200_000, lfsAllocatedBytes: 1_800_000, fileCount: 412)
        func entry(
            _ rel: String, in base: URL, cat: HeavyFolderCategory, status: HeavyFolderStatus, bytes: UInt64, files: Int
        ) -> HeavyFolderEntry {
            HeavyFolderEntry(
                relativePath: rel, url: base.appendingPathComponent(rel),
                category: cat, status: status, allocatedBytes: bytes, fileCount: files)
        }
        let mainEntries = [
            entry(
                "node_modules", in: root, cat: .javascript, status: .reclaimable, bytes: 2_650_000_000, files: 48_210),
            entry(".next", in: root, cat: .buildOutput, status: .reclaimable, bytes: 980_000_000, files: 3_420),
            entry(
                "public/media", in: root, cat: .otherLarge, status: .trackedOrUnignored, bytes: 130_000_000, files: 84),
        ]
        let madtom = parent.appendingPathComponent("madtom")
        let madtomEntries = [
            entry(
                "node_modules", in: madtom, cat: .javascript, status: .reclaimable, bytes: 1_720_000_000,
                files: 46_100),
            entry(".turbo", in: madtom, cat: .cache, status: .reclaimable, bytes: 130_000_000, files: 620),
        ]
        let pyrosome = parent.appendingPathComponent("pyrosome")
        let pyrosomeEntries = [
            entry(
                "node_modules", in: pyrosome, cat: .javascript, status: .reclaimable, bytes: 1_840_000_000,
                files: 47_500)
        ]
        let guides = parent.appendingPathComponent("bambu-phone-guides")
        let guidesEntries = [
            entry(".venv", in: guides, cat: .python, status: .reclaimable, bytes: 680_000_000, files: 14_200)
        ]
        return RepositoryStorageReport(
            mainRoot: root, gitStore: git,
            checkouts: [
                CheckoutStorageReport(
                    path: root, isMainWorktree: true,
                    worktree: GitWorktree(path: root.path, branch: "main", head: "a1b2c3d"),
                    totalAllocatedBytes: 3_760_000_000, totalLogicalBytes: 3_760_000_000,
                    fileCount: 52_000, heavyFolders: mainEntries, lastModifiedDate: now),
                CheckoutStorageReport(
                    path: madtom, isMainWorktree: false,
                    worktree: GitWorktree(
                        path: madtom.path, branch: "rolottr/bambu-bar-website-posthog", head: "b2c3d4e"),
                    totalAllocatedBytes: 1_850_000_000, totalLogicalBytes: 1_850_000_000,
                    fileCount: 47_000, heavyFolders: madtomEntries, lastModifiedDate: now),
                CheckoutStorageReport(
                    path: pyrosome, isMainWorktree: false,
                    worktree: GitWorktree(path: pyrosome.path, branch: "chore/bump-posthog-js", head: "c3d4e5f"),
                    totalAllocatedBytes: 1_840_000_000, totalLogicalBytes: 1_840_000_000,
                    fileCount: 47_900, heavyFolders: pyrosomeEntries,
                    lastModifiedDate: now.addingTimeInterval(-42 * 86_400)),
                CheckoutStorageReport(
                    path: guides, isMainWorktree: false,
                    worktree: GitWorktree(path: guides.path, branch: "rolottr/bambu-phone-guides", head: "d4e5f6a"),
                    totalAllocatedBytes: 711_100_000, totalLogicalBytes: 711_100_000,
                    fileCount: 15_000, heavyFolders: guidesEntries,
                    lastModifiedDate: now.addingTimeInterval(-2 * 86_400)),
            ],
            isPartial: false)
    }
}
