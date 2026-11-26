import AppKit
import GitaCore
import Testing
import WebKit

@testable import GitaUI

@MainActor
struct SmartDiffPresenterTests {
    private let text =
        "@@ -1 +1 @@\n- old()\n+old()\n@@ -4,3 +4,0 @@\n-alpha\n-beta\n-gamma\n"
        + "@@ -8,0 +8,3 @@\n+alpha\n+beta\n+gamma\n"

    @Test func sparklineInteraction() throws {
        let presenter = VelocitySparklinePresenter()
        #expect(presenter.state == .idle)
        presenter.update([])
        #expect(presenter.state == .empty)
        let commits = [0, 60].map {
            GitCommit(
                id: String($0), parents: [], subject: "", author: "A", date: Date(timeIntervalSince1970: Double($0)))
        }
        let buckets = HistoryVelocityAggregator.aggregate(
            commits: commits, fileChurnByCommit: ["60": 2], bucketCount: 2)
        presenter.update(buckets)
        presenter.hover(at: 1.2)
        #expect(presenter.activeBucket == buckets[1])
        #expect(presenter.tooltip(for: buckets[1]).contains("1 commit"))
        #expect(presenter.tooltip(for: buckets[1]).contains("2 file changes"))
        presenter.step(-1)
        #expect(presenter.activeBucket == buckets[0])
        presenter.step(-1)
        #expect(presenter.activeBucket == buckets[0])
        var jumped: VelocityBucket?
        let view = SmartDiffFacade.shared.makeVelocitySparklineView(commits: commits) { jumped = $0 }
        #expect(view.accessibilityPerformIncrement())
        #expect(view.accessibilityPerformPress() && jumped?.representativeCommitID == "0")
    }

    @Test func orderModesAndDisclosure() throws {
        let file = NarrativeFileEntry(path: "Package.resolved", additions: 2, deletions: 1)
        let presenter = NarrativeOrderPresenter(entries: [file])
        let group = try #require(presenter.groups.first)
        #expect(presenter.collapsedLayers.contains(group.layer))
        let header = SmartDiffFacade.shared.makeNarrativeHeaderView(group: group, presenter: presenter)
        #expect(header.accessibilityPerformPress())
        #expect(!presenter.collapsedLayers.contains(group.layer))
        #expect(header.isAccessibilityExpanded())
        #expect(header.accessibilityLabel() == NarrativeOrderPresenter.summary(group))
        presenter.toggle(group.layer)
        #expect(!header.isAccessibilityExpanded())
        presenter.setMode(.alphabetical)
        #expect(presenter.groups.first?.entries == [file])
        #expect(presenter.mode == .alphabetical)
    }

    @Test func unifiedRowsAndMoveDestinations() async throws {
        let presenter = SmartDiffPresenter()
        #expect(presenter.state == .idle)
        let task = presenter.load(diffText: text, filePath: "main.swift")
        #expect(presenter.state == .loading)
        await task.value
        guard case .loaded(let snapshot) = presenter.state else {
            Issue.record("Expected raw diff")
            return
        }
        #expect(snapshot.filtered.hiddenNoiseHunkCount == 1)
        #expect(
            snapshot.displayRows.first
                == snapshot.filtered.collapsedNoiseRuns.first.map(SmartDiffRow.collapsedNoisePill))
        let match = try #require(snapshot.moves.matches.first)
        let target = presenter.jumpTarget(forMoveID: match.id, fromLineIndex: match.source.lineIndices.lowerBound + 1)
        #expect(target?.lineIndex == match.destination.lineIndices.lowerBound + 1)
        presenter.toggleNoiseRun(hunkIndices: [0])
        guard case .loaded(let expanded) = presenter.state else {
            Issue.record("Expected expanded diff")
            return
        }
        #expect(expanded.filtered.hiddenNoiseHunkIndices.isEmpty)
        presenter.toggleNoiseFilter()
        #expect(!presenter.options.hideNoise)
        presenter.toggleMoveDetection()
        #expect(presenter.jumpTarget(forMoveID: match.id, fromLineIndex: match.source.lineIndices.lowerBound) == nil)
        await presenter.load(diffText: "", filePath: "empty").value
        #expect(presenter.state == .empty)
    }

    @Test func crossFileAndStaleLoads() async throws {
        let presenter = SmartDiffPresenter()
        let first = presenter.load(diffText: text, filePath: "old.swift")
        let other = UnifiedDiff.parse("@@ -1,0 +1,3 @@\n+alpha\n+beta\n+gamma\n")
        await presenter.load(
            diffText: "@@ -1,3 +1,0 @@\n-alpha\n-beta\n-gamma\n", filePath: "a.swift",
            relatedDocuments: ["b.swift": other]
        ).value
        await first.value
        guard case .loaded(let snapshot) = presenter.state else {
            Issue.record("Expected latest diff")
            return
        }
        let id = try #require(snapshot.moves.matches.first?.id)
        #expect(presenter.jumpTarget(forMoveID: id, fromLineIndex: 1)?.filePath == "b.swift")
    }

    @Test func structuredToggleAndRetry() async {
        let presenter = SmartDiffPresenter()
        await presenter.load(diffText: "@@ -1 +1 @@\n-1\n+2", oldText: "1", newText: "2", filePath: "a.json").value
        guard case .loaded(let parsed) = presenter.state, case .structuredEntry = parsed.displayRows.first
        else {
            Issue.record("Expected structured row")
            return
        }
        presenter.toggleStructuredMode()
        guard case .loaded(let raw) = presenter.state, case .diffLine = raw.displayRows.first
        else {
            Issue.record("Expected raw row")
            return
        }
        var retried = false
        presenter.fail("Read failed") { retried = true }
        #expect(presenter.state == .failed("Read failed"))
        presenter.retry()
        #expect(retried)
    }

    @Test func previewModesAndNavigationLifecycle() throws {
        let prod = try #require(URL(string: "https://live.test"))
        let preview = try #require(URL(string: "https://preview.test"))
        let presenter = VisualPreviewDiffPresenter(productionURL: prod, previewURL: preview)
        presenter.setRoute("//elsewhere.test/path?q=1")
        #expect(presenter.resolvedURLs?.production.absoluteString == "https://live.test/path?q=1")
        #expect(presenter.resolvedURLs?.preview.absoluteString == "https://preview.test/path?q=1")
        presenter.setMode(.curtain)
        presenter.setCurtainPosition(-1)
        #expect(presenter.mode == .curtain && presenter.curtainPosition == 0.05)
        presenter.setCurtainPosition(1)
        #expect(presenter.curtainPosition == 0.95)
        presenter.setViewport(.mobile)
        #expect(presenter.viewport.size == CGSize(width: 390, height: 844))
        presenter.setMode(.onionSkin)
        presenter.setOnionOpacity(2)
        #expect(presenter.mode == .onionSkin && presenter.onionOpacity == 1)
        presenter.beginLoading()
        presenter.finished(production: false)
        #expect(presenter.state == .loading(productionLoaded: false, previewLoaded: true))
        presenter.finished(production: true)
        #expect(presenter.state == .ready)
    }

    @Test func clickingNoisePillRevealsOriginalLine() async throws {
        let controller = SmartDiffFacade.shared.makeSmartDiffViewController()
        let window = UITestSupport.host(controller)
        defer { window.close() }
        await controller.presenter.load(diffText: text, filePath: "main.swift").value
        window.layoutIfNeeded()
        let table = try #require(descendant(NSTableView.self, in: controller.view))
        #expect(table.bounds.width > 0 && table.bounds.height > 0)
        let initial = table.numberOfRows
        let cell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        let button = try #require(descendant(PartsButton.self, in: cell))
        #expect(button.accessibilityPerformPress())
        #expect(table.numberOfRows == initial + 2)
        #expect(table.selectedRow == 0)
        controller.cancelOperation(nil)
        #expect(table.numberOfRows == initial)
    }

    private func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews {
            if let match = descendant(type, in: child) { return match }
        }
        return nil
    }

    @Test func comparisonGeometry() throws {
        UITestSupport.bootstrap()
        let url = try #require(URL(string: "https://example.test"))
        let pair = VisualPreviewPair(productionURL: url, previewURL: url, title: "Comparison")
        let controller = VisualPreviewDiffWindowController(pair: pair)
        let view = controller.comparison
        defer { view.tearDown() }
        let window = try #require(controller.window)
        view.presenter.beginLoading()
        window.layoutIfNeeded()
        let live = view.productionWebView
        let preview = view.previewWebView
        let clip = try #require(preview.superview)
        #expect(live.frame.width > 0 && live.frame.height > 0)
        #expect(clip.frame.minX >= live.frame.maxX)
        view.presenter.setViewport(.mobile)
        view.presenter.setMode(.curtain)
        view.presenter.setCurtainPosition(0.25)
        window.layoutIfNeeded()
        #expect(live.frame.size == VisualPreviewViewport.mobile.size)
        let split = (live.frame.width * 0.25).rounded()
        #expect(clip.frame.minX == live.frame.minX + split)
        #expect(clip.frame.maxX == live.frame.maxX)
        #expect(preview.convert(preview.bounds, to: live) == live.bounds)
        view.presenter.setMode(.onionSkin)
        view.presenter.setOnionOpacity(0.25)
        window.layoutIfNeeded()
        #expect(clip.frame == live.frame && preview.alphaValue == 0.25)
    }

    @Test func windowReuseAndTeardown() throws {
        UITestSupport.bootstrap()
        let facade = SmartDiffFacade()
        // Validation fails before WebKit receives a request. Exercise the actual window close/delegate path.
        let invalid = try #require(URL(string: "http://invalid.test"))
        let preview = try #require(URL(string: "https://preview.test"))
        let first = facade.openVisualPreviewDiff(productionURL: invalid, previewURL: preview)
        #expect(facade.openVisualPreviewDiff(productionURL: invalid, previewURL: preview) === first)
        let web = first.comparison.previewWebView
        #expect(web.navigationDelegate != nil)
        first.close()
        #expect(web.navigationDelegate == nil && web.superview == nil)
        #expect(web.configuration.userContentController.userScripts.isEmpty)
        let second = facade.openVisualPreviewDiff(productionURL: invalid, previewURL: preview)
        #expect(second !== first)
        second.close()
    }
}
