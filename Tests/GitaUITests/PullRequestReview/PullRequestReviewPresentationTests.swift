import AppKit
import Foundation
import Testing

@testable import GitaCore
@testable import GitaUI

@MainActor
@Suite("Pull request review presentation and pop-out")
struct PullRequestReviewPresentationTests {
    private func open(
        _ runner: ReviewTestRunner = ReviewTestRunner()
    ) async throws -> PullRequestReviewController {
        UITestSupport.bootstrap()
        let controller = PullRequestReviewController(
            target: try #require(ReviewTestRunner.item.target),
            root: URL(fileURLWithPath: "/tmp/pr-\(UUID().uuidString)"),
            service: PullRequestReviewService(runner: runner))
        try await SetupTestSupport.waitUntil("PR review loads") { !controller.state.isLoading }
        return controller
    }

    @Test func presentationAndCollapseThresholds() {
        #expect(ReviewPresentation.preferred(forWidth: 899) == .inline)
        #expect(ReviewPresentation.preferred(forWidth: 900) == .page)
        #expect(ReviewPresentation.preferred(forWidth: 1_200) == .page)
        #expect(!ReviewPresentation.inline.collapsesSidebar(forWidth: 800))
        #expect(ReviewPresentation.page.collapsesSidebar(forWidth: 1_099))
        #expect(!ReviewPresentation.page.collapsesSidebar(forWidth: 1_100))
        #expect(ReviewPresentation.window.collapsesSidebar(forWidth: 950))
    }

    @Test func reviewViewAdaptsChromeHeightAndCompactSidebar() async throws {
        let controller = try await open()
        let view = controller.reviewView
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 860))
        Style.fill(view, in: host)
        view.setPresentation(.page)
        host.layoutSubtreeIfNeeded()
        #expect(view.presentation == .page)
        #expect(view.frame.height > 800, "full-height page mode removes the 620 pt card cap")
        #expect(!view.backButton.isHidden && !view.windowButton.isHidden)
        #expect(view.layer?.borderWidth == 0)
        #expect(!view.sidebar.isCompact)

        // Collapse to icon sidebar below 1,100 pt.
        host.frame = NSRect(x: 0, y: 0, width: 980, height: 860)
        host.layoutSubtreeIfNeeded()
        #expect(view.sidebar.isCompact)

        // Inline fallback restores 620 pt card chrome.
        view.removeFromSuperview()
        view.setPresentation(.inline)
        view.frame = NSRect(x: 0, y: 0, width: 850, height: PullRequestReviewView.inlineHeight)
        view.layoutSubtreeIfNeeded()
        #expect(view.backButton.isHidden && !view.windowButton.isHidden)
        #expect(view.layer?.borderWidth == 1 && view.layer?.cornerRadius == 8)
        #expect(!view.sidebar.isCompact)
    }

    @Test func listDetailWorkspaceHandlesThresholds() async throws {
        let controller = try await open()
        let workspace = PullRequestReviewWorkspaceView(frame: NSRect(x: 0, y: 0, width: 1_200, height: 800))
        var collapses: [Bool] = []
        workspace.onCollapseChanged = { collapses.append($0) }
        workspace.showReview(controller.reviewView)
        workspace.layoutSubtreeIfNeeded()
        #expect(workspace.layoutState.presentation == .page)
        #expect(!workspace.layoutState.collapsesListToIcons)
        #expect(workspace.layoutState.showsDetail && !workspace.detailHost.isHidden)

        workspace.frame = NSRect(x: 0, y: 0, width: 1_000, height: 800)
        workspace.layoutSubtreeIfNeeded()
        #expect(workspace.layoutState.collapsesListToIcons && collapses.last == true)
        #expect(controller.reviewView.presentation == .page)

        workspace.frame = NSRect(x: 0, y: 0, width: 850, height: 800)
        workspace.layoutSubtreeIfNeeded()
        #expect(workspace.layoutState.presentation == .inline && workspace.detailHost.isHidden)
        #expect(controller.reviewView.presentation == .inline)

        workspace.frame = NSRect(x: 0, y: 0, width: 1_150, height: 800)
        workspace.layoutSubtreeIfNeeded()
        #expect(workspace.layoutState.presentation == .page && !workspace.detailHost.isHidden)
        #expect(controller.reviewView.superview === workspace.detailHost)

        workspace.clearReview()
        #expect(workspace.activeReview == nil && workspace.detailHost.isHidden)
    }

    @Test func viewedCheckmarksAndWordDiffUpdateState() async throws {
        let controller = try await open()
        var backTapped = false
        controller.onBack = { backTapped = true }
        controller.reviewView.setPresentation(.page)
        controller.reviewView.backButton.onClick?()
        #expect(backTapped)

        #expect(controller.state.viewedCount == 0)
        controller.toggleViewed("README.md")
        #expect(controller.state.isViewed("README.md") && controller.state.viewedCount == 1)
        #expect(controller.reviewView.sidebar.rows.last?.isViewed == true)

        controller.select(.file("README.md"))
        let filePage = controller.reviewView.filePage
        #expect(filePage.viewedButton.accessibilityValue() as? String == String(localized: "Viewed"))
        filePage.viewedButton.onClick?()
        #expect(!controller.state.isViewed("README.md") && controller.state.viewedCount == 0)

        // Word-level diff highlights are computed on ReviewDiffView for paired -/+ lines.
        let highlights = filePage.diff.wordHighlights
        #expect(highlights.contains { !$0.isEmpty })
    }

    @Test func popOutWindowReusesSameViewAndState() async throws {
        let controller = try await open()
        controller.state.draft.body = "Keep this draft"
        let originalView = controller.reviewView
        var returned: PullRequestReviewView?
        controller.onReturnFromWindow = { returned = $0 }
        controller.reviewView.windowButton.onClick?()
        let popOut = try #require(controller.popOutWindow)
        let window = try #require(popOut.window)
        #expect(originalView.presentation == .window)
        #expect(originalView.backButton.isHidden && originalView.windowButton.isHidden)
        #expect(originalView.isDescendant(of: try #require(window.contentView)))
        #expect(controller.state.draft.body == "Keep this draft")
        #expect(controller.reviewView === originalView)

        window.close()
        #expect(controller.popOutWindow == nil)
        #expect(returned === originalView)
        #expect(!controller.isRetired, "closing pop-out returns the review rather than retiring it")

        // Can pop out again after returning from the pop-out window.
        let host = NSWindow()
        host.isReleasedWhenClosed = false
        host.contentView = controller.reviewView
        returned = nil
        controller.popOutToWindow()
        let second = try #require(controller.popOutWindow?.window)
        host.close()
        #expect(controller.isRetired && controller.popOutWindow == nil)
        #expect(!second.isVisible && returned == nil)
    }
}
