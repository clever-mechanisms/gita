import AppKit
import Foundation
import Testing

@testable import GitaCore
@testable import GitaUI

@MainActor
@Suite("Inline error banners and actionable empty states")
struct ContentBannerAndEmptyStateTests {
    private func partsButton(_ identifier: String, in root: NSView) throws -> PartsButton {
        try #require(
            SetupTestSupport.views(PartsButton.self, in: root).first {
                $0.accessibilityIdentifier() == identifier
            })
    }

    @Test func contentBannerViewRendersRetryDetailsAndDismiss() throws {
        UITestSupport.bootstrap()
        let sandbox = try SetupSandbox()
        let model = AppModel(defaults: sandbox.defaults)
        let controller = RepositoryViewController(model: model)
        let window = UITestSupport.host(controller, size: NSSize(width: 1_000, height: 700))
        defer {
            controller.detach()
            window.close()
        }

        let bannerView = controller.contentBanner
        #expect(bannerView.isHidden)

        var retried = 0
        let retry = ContentBanner.RetryAction(title: String(localized: "Retry")) { retried += 1 }
        model.showNonDestructiveError(
            String(localized: "Fetch"), String(localized: "This repository has no remote."), retry: retry)
        controller.view.layoutSubtreeIfNeeded()
        #expect(!bannerView.isHidden)
        #expect(bannerView.frame.height == ContentBannerView.height)
        #expect(bannerView.banner.displayText == "Fetch: This repository has no remote.")

        let retryBtn = try partsButton("contentBanner.retry", in: bannerView)
        retryBtn.onClick?()
        #expect(retried == 1)
        #expect(model.contentBanner == .none)
        #expect(bannerView.isHidden)

        model.showBanner(.info(String(localized: "Check out a branch to pull into.")))
        #expect(!bannerView.isHidden && !bannerView.banner.isFailure)
        let dismissBtn = try partsButton("contentBanner.dismiss", in: bannerView)
        dismissBtn.onClick?()
        #expect(model.contentBanner == .none)

        #expect(ContentBanner.none.displayText.isEmpty)
        #expect(ContentBanner.failure(title: "", message: "Only msg", retry: nil).displayText == "Only msg")
        #expect(ContentBanner.failure(title: "Only title", message: "", retry: nil).displayText == "Only title")
    }

    @Test func alertPresenterRetainsDestructiveModalAlerts() throws {
        UITestSupport.bootstrap()
        var shown: [String] = []
        let original = AlertPresenter.shared
        defer { AlertPresenter.shared = original }
        let presenter = AlertPresenter { alert, _, completion in
            shown.append("\(alert.messageText): \(alert.informativeText)")
            completion(.alertFirstButtonReturn)
        }
        presenter.showDestructiveError("Reset", "Cannot undo")
        #expect(shown == ["Reset: Cannot undo"])
    }

    @Test func cleanTreeEmptyStateShowsLastCommitAheadAndPushAction() throws {
        UITestSupport.bootstrap()
        let sandbox = try SetupSandbox()
        let pane = FilePaneView(defaults: sandbox.defaults)
        pane.frame = NSRect(x: 0, y: 0, width: 320, height: 480)
        pane.show(.localChanges)
        let twoHoursAgo = Date().addingTimeInterval(-7_200)
        let context = CleanTreeContext(lastCommitDate: twoHoursAgo, ahead: 2, hasUpstream: true, canPush: true)
        pane.cleanTreeContext = context
        pane.showChanges([])
        pane.layoutSubtreeIfNeeded()

        let text = CleanTreeEmptyState.message(context)
        #expect(text.contains(String(localized: "Working tree clean")))
        #expect(text.contains("↑2"))
        var pushed = false
        pane.onPush = { pushed = true }
        let pushButton = try partsButton("changes.cleanPush", in: pane)
        #expect(!pushButton.isHidden)
        pushButton.onClick?()
        #expect(pushed)

        // Adding a changed file hides the clean-tree overlay.
        pane.showChanges([FileChange(path: "a.swift", indexStatus: " ", worktreeStatus: "M")])
        #expect(pushButton.superview?.superview?.isHidden == true)
    }

    @Test func binaryDiffEmptyViewFormatsSizesAndInvokesActions() throws {
        UITestSupport.bootstrap()
        let fileURL = URL(fileURLWithPath: "/tmp/archive.bin")
        let summary = BinaryDiffSummary(
            path: "archive.bin", oldByteCount: 1_200_000, newByteCount: 1_300_000, fileURL: fileURL)
        #expect(summary.message.contains("→"))
        #expect(BinaryDiffSummary.isBinaryDiff("Binary files a/img.png and b/img.png differ"))
        #expect(BinaryDiffSummary.isBinaryDiff("GIT binary patch\nliteral 0"))
        #expect(!BinaryDiffSummary.isBinaryDiff("@@ -1 +1 @@\n-a\n+b"))
        #expect(
            BinaryDiffSummary(path: "x.bin", oldByteCount: nil, newByteCount: 512, fileURL: nil).canRevealOrOpen
                == false)
        let added = BinaryDiffSummary(path: "added.bin", oldByteCount: nil, newByteCount: 2_048, fileURL: nil)
        let removed = BinaryDiffSummary(path: "old.bin", oldByteCount: 2_048, newByteCount: nil, fileURL: nil)
        let unknown = BinaryDiffSummary(path: "unknown.bin", oldByteCount: nil, newByteCount: nil, fileURL: nil)
        #expect(added.message.contains("Binary file") && !added.message.contains("→"))
        #expect(removed.message.contains("→"))
        #expect(unknown.message == String(localized: "Binary file"))

        let view = BinaryDiffEmptyView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        var opened: URL?
        var revealed: URL?
        view.onOpen = { opened = $0 }
        view.onRevealInFinder = { revealed = $0 }
        view.show(summary)
        #expect(!view.isHidden)

        let openBtn = try partsButton("binaryDiff.open", in: view)
        let revealBtn = try partsButton("binaryDiff.reveal", in: view)
        #expect(openBtn.isEnabled && revealBtn.isEnabled)
        openBtn.onClick?()
        revealBtn.onClick?()
        #expect(opened == fileURL && revealed == fileURL)

        view.show(nil)
        #expect(view.isHidden)
    }
}
