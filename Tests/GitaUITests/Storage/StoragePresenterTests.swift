import AppKit
import Foundation
import Testing

@testable import GitaCore
@testable import GitaUI

@Suite struct StoragePresenterTests {
    let presenter = StoragePresenter()
    let root = URL(fileURLWithPath: "/sample/repo")

    @Test func byteFormattingAndProportions() {
        let report = StoragePresentationFixture.report(root)
        #expect(presenter.formatBytes(1_000) == ByteCountFormatter.string(fromByteCount: 1_000, countStyle: .file))
        let segments = presenter.summarySegments(for: report)
        #expect(segments.map(\.fraction) == [0.40, 0.08, 0.52])
        #expect(segments.map(\.percentText) == ["40%", "8%", "52%"])
        #expect(presenter.formatPercent(0.004) == "<1%")
        #expect(segments.allSatisfy { !$0.tooltip.isEmpty })
        #expect(presenter.selectedBytes(for: [root.path + "/linked/node_modules"], in: report) == 8)
        #expect(presenter.summarySubtitle(for: report).contains("reclaimable"))
        #expect(presenter.cleanButtonTitle(selectedPaths: [], in: report).contains("Clean"))
        #expect(
            presenter.cleanButtonTitle(selectedPaths: [root.path + "/linked/node_modules"], in: report)
                .contains("Clean"))
    }

    @Test func outlineShowsBranchesAgentsStalenessSymbolsAndRestrictsSelection() {
        let report = StoragePresentationFixture.report(root)
        let nodes = presenter.outlineNodes(
            for: report, activeAgentPaths: [root.path + "/linked"],
            now: StoragePresentationFixture.now)
        #expect(nodes.map(\.bytes) == [40, 50, 10])
        #expect(
            nodes[0].kind == .gitStore && nodes[0].symbolName == "cylinder.split.1x2.fill" && nodes[0].tone == .blue)
        #expect(nodes[0].children.map(\.bytes) == [10, 5, 25])
        #expect(nodes[0].children.map(\.symbolName) == ["archivebox.fill", "externaldrive.fill", "doc.text.fill"])
        #expect(nodes[0].children.map(\.tone) == [.blue, .teal, .neutral])
        #expect(nodes[1].kind == .worktree && nodes[1].symbolName == Deck.worktreeSymbol && nodes[1].tone == .indigo)
        #expect(nodes[1].branch == "topic")
        #expect(nodes[1].warning != nil)
        #expect(nodes[1].reclaimableBytes == 8)
        #expect(nodes[2].kind == .mainCheckout && nodes[2].symbolName == "folder.fill" && nodes[2].tone == .accent)
        #expect(nodes[2].warning == nil)
        #expect(nodes[1].caption == String(localized: "Stale · \(45)d ago"))
        #expect(nodes[1].children.filter(\.isSelectable).map(\.title) == ["node_modules"])
        #expect(nodes[1].children.map(\.symbolName) == ["folder.fill", "hammer.fill", "shippingbox.fill"])
        #expect(nodes[1].children.map(\.tone) == [.neutral, .orange, .green])
        #expect(nodes.allSatisfy { !$0.isSelectable })

        let cacheEntry = HeavyFolderEntry(
            relativePath: ".venv", url: root.appendingPathComponent(".venv"),
            category: .python, status: .reclaimable, allocatedBytes: 12, fileCount: 1)
        #expect(StorageOutlineNode.heavyFolderSymbol(for: cacheEntry) == "cube.fill")
        #expect(StorageOutlineNode.heavyFolderSymbol(for: nil) == "folder.fill")
    }

    @MainActor @Test func outlineOffersCheckboxOnlyOnReclaimableRow() throws {
        let report = StoragePresentationFixture.report(root)
        let nodes = presenter.outlineNodes(for: report, activeAgentPaths: [], now: StoragePresentationFixture.now)
        let view = StorageOutlineView(frame: NSRect(x: 0, y: 0, width: 800, height: 450))
        let outline = try #require(view.documentView as? NSOutlineView)
        view.display(nodes)
        outline.expandItem(nil, expandChildren: true)
        var checks = [NSButton]()
        for row in 0..<outline.numberOfRows {
            let item = try #require(outline.item(atRow: row))
            let cell = view.outlineView(outline, viewFor: outline.outlineTableColumn, item: item)
            if let cell {
                checks += SharedFixtures.descendants(cell, of: NSButton.self)
            }
            let bytesCol = outline.tableColumn(withIdentifier: .init("bytes"))
            #expect(view.outlineView(outline, viewFor: bytesCol, item: item) != nil)
        }
        #expect(checks.count == 1)
        let checkbox = try #require(checks.first)
        checkbox.performClick(nil)
        #expect(view.checked == Set([root.path + "/linked/node_modules"]))
    }

    @Test func ranksWorkspaceAgainstLargestReport() {
        let small = StoragePresentationFixture.report(root)
        let large = StoragePresentationFixture.report(root.appendingPathComponent("big"), gitBytes: 140)
        let rows = presenter.workspaceRows(for: [small, large])
        #expect(rows.map(\.root) == [large.mainRoot, small.mainRoot])
        #expect(rows.map(\.share) == [1, 0.5])
        #expect(rows.map(\.worktreeCount) == [2, 2])
        #expect(rows.map(\.reclaimableBytes) == [8, 8])
    }

    @Test func healthCardsAndSummaryDescribeCustomHookAndSafeGCForActiveAgents() {
        let external = "/external/orca-worktree"
        let health = RepositoryHealthSnapshot(
            worktreePaths: [root.path, external], fsMonitor: .customHook("./monitor"),
            untrackedCache: .enabled, commitGraph: CommitGraphInfo(path: nil, modifiedAt: nil),
            maintenance: GitMaintenanceInfo(
                automatic: .disabled, isRegistered: true, looseObjects: 12,
                packedObjects: 2, packs: 1, looseKiB: 4, packedKiB: 8),
            fsMonitorScope: .local, untrackedCacheScope: .global)
        #expect(
            presenter.hasActiveAgent(
                in: root, snapshot: health, report: nil, activeAgentPaths: [external + "/subdir"]))
        #expect(
            !presenter.hasActiveAgent(
                in: root, snapshot: health, report: nil, activeAgentPaths: ["/other/repo"]))
        #expect(
            presenter.hasActiveAgent(
                in: root, snapshot: nil, report: nil, activeAgentPaths: ["/other/repo"]))
        let summary = presenter.healthSummary(for: health, actionState: .idle)
        #expect(summary.enabledCount == 3 && summary.totalCount == 4)
        #expect(summary.scopeBadge.contains(".git/config"))
        #expect(summary.subtitle.contains(".git/config"))
        #expect(
            summary.status
                == .recommend(
                    .enableRecommended(
                        fsMonitor: false, untrackedCache: false, commitGraph: true, registerMaintenance: false)))
        #expect(presenter.healthSummary(for: health, actionState: .running("GC")).status == .updating)
        let running = presenter.healthCards(for: health, actionState: .running("GC"), hasActiveAgent: true)
        #expect(running.count == 5)
        #expect(running.allSatisfy { !$0.enabled })
        #expect(running[0].control == .button)
        #expect(running[0].action == .replaceCustomFSMonitor("./monitor"))
        #expect(running[0].detail.contains("./monitor"))
        #expect(running[0].scopeOrigin == .thisRepo)
        #expect(running[1].control == .toggle(true))
        #expect(running[1].scopeOrigin == .inheritedGlobal)
        #expect(running[3].action == .garbageCollection(pruneNow: false))
        #expect(running[3].statPills.first?.contains("12") == true)
        #expect(running[4].secondaryToggle?.isOn == true)
        #expect(running[4].scopeOrigin == .thisRepo)
        let idle = presenter.healthCards(for: health, actionState: .idle, hasActiveAgent: false)
        #expect(idle[3].action == .garbageCollection(pruneNow: true))
    }

    @Test func trashPlanSkipsActiveAgentsByDefaultAndWarnsWhenExplicit() throws {
        let report = StoragePresentationFixture.report(root)
        let linked = root.path + "/linked"
        let bulk = presenter.trashPlan(report: report, entry: nil, checked: [], activeAgentPaths: [linked])
        #expect(bulk.groups.isEmpty)
        #expect(bulk.skippedActiveCount == 1)
        let entry = try #require(report.checkouts.last?.heavyFolders.first)
        let explicit = presenter.trashPlan(
            report: report, entry: nil, checked: [entry.id], activeAgentPaths: [linked])
        #expect(explicit.groups.count == 1)
        #expect(explicit.activeAgentNames == ["linked"])
        #expect(explicit.skippedActiveCount == 0)
    }
}
