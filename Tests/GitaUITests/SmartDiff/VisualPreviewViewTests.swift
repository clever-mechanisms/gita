import AppKit
import GitaCore
import Testing
import WebKit

@testable import GitaUI

@MainActor
struct VisualPreviewViewTests {
    private func comparison() throws -> VisualPreviewDiffView {
        UITestSupport.bootstrap()
        let url = try #require(URL(string: "https://deployment.test"))
        return VisualPreviewDiffView(presenter: VisualPreviewDiffPresenter(productionURL: url, previewURL: url))
    }

    @Test func emptyAndFailedStatesReplaceCanvasAndStatus() throws {
        let view = try comparison()
        defer { view.tearDown() }
        let canvas = try #require(SharedFixtures.descendants(view, of: VisualPreviewCanvas.self).first)
        let button = try #require(
            SharedFixtures.descendants(view, of: PartsButton.self).first {
                $0.accessibilityLabel() == "Load Comparison"
            })
        let message = try #require(
            SharedFixtures.descendants(view, of: NSTextField.self).first {
                $0.stringValue == "Compare production and preview deployments"
            })
        #expect(canvas.isHidden && !message.isHiddenOrHasHiddenAncestor)
        #expect(message.textColor == Theme.secondaryText && message.font == Theme.caption)
        #expect(button.fixedHeight == 22 && button.background == .quiet)
        #expect(button.accessibilityPerformPress())
        #expect(!canvas.isHidden && message.isHiddenOrHasHiddenAncestor)
        let caption = try #require(
            SharedFixtures.descendants(view, of: NSTextField.self).first {
                $0.stringValue == view.presenter.statusCaption
            })
        let status = try #require(caption.superview)
        view.presenter.fail("Deployment unavailable")
        #expect(canvas.isHidden && status.isHiddenOrHasHiddenAncestor)
        #expect(button.accessibilityLabel() == "Retry")
        #expect(message.stringValue == "Deployment unavailable" && message.textColor == Theme.failure)
        #expect(!message.isHiddenOrHasHiddenAncestor)
        #expect(button.accessibilityPerformPress() && !canvas.isHidden)
    }

    @Test func commitRevealsOnlyItsPaneAndReloadHidesBoth() throws {
        let view = try comparison()
        defer { view.tearDown() }
        let live = view.productionWebView
        let preview = view.previewWebView
        #expect(live.isHidden && preview.isHidden)
        for web in [live, preview] {
            let background = try #require(web.underPageBackgroundColor.usingColorSpace(.sRGB))
            let inset = try #require(Theme.inset.usingColorSpace(.sRGB))
            #expect(abs(background.redComponent - inset.redComponent) < 0.005)
            #expect(abs(background.greenComponent - inset.greenComponent) < 0.005)
            #expect(abs(background.blueComponent - inset.blueComponent) < 0.005)
        }
        view.presenter.beginLoading()
        let page = try #require(live.loadHTMLString("", baseURL: nil))
        view.webView(live, didStartProvisionalNavigation: page)
        view.webView(live, didCommit: page)
        #expect(!live.isHidden && preview.isHidden)
        view.reload()
        view.webView(live, didCommit: page)
        #expect(live.isHidden && preview.isHidden)
    }

    @Test func navigationPoliciesProtectMainFrameAndPermitEmbeddedContent() throws {
        let view = try comparison()
        defer { view.tearDown() }
        view.presenter.beginLoading()
        view.presenter.finished(production: true)
        view.presenter.finished(production: false)
        for string in ["about:blank", "data:text/html,abc", "blob:https://deployment.test/id"] {
            let url = try #require(URL(string: string))
            #expect(view.allowsNavigation(to: url, target: .subframe))
            #expect(!view.allowsNavigation(to: url, target: .mainFrame, linkActivated: true))
            #expect(!view.allowsNavigation(to: url, target: .newWindow))
        }
        let http = try #require(URL(string: "http://deployment.test"))
        #expect(!view.allowsNavigation(to: http, target: .mainFrame, linkActivated: true))
        #expect(!view.allowsNavigation(to: http, target: .subframe))
        #expect(view.allowsNavigation(to: view.presenter.productionURL, target: .mainFrame))
        #expect(view.presenter.state == .ready)
        #expect(!view.allowsNavigation(to: http, target: .mainFrame))
        #expect(view.presenter.state == .failed("This comparison requires an HTTPS address."))
    }

    @Test func interruptedAndCancelledLoadsSettleAndPreservePolicyFailures() throws {
        let view = try comparison()
        defer { view.tearDown() }
        let web = view.previewWebView
        for error in [
            NSError(domain: "WebKitErrorDomain", code: 102),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled),
        ] {
            view.presenter.beginLoading()
            web.isHidden = true
            let navigation = try #require(web.loadHTMLString("", baseURL: nil))
            view.webView(web, didStartProvisionalNavigation: navigation)
            view.webView(web, didFailProvisionalNavigation: navigation, withError: error)
            #expect(view.presenter.state == .failed("The deployment couldn’t be shown."))
        }
        view.presenter.beginLoading()
        view.presenter.finished(production: true)
        let visibleNav = try #require(web.loadHTMLString("", baseURL: nil))
        view.webView(web, didStartProvisionalNavigation: visibleNav)
        view.webView(web, didCommit: visibleNav)
        view.webView(web, didFail: visibleNav, withError: NSError(domain: "WebKitErrorDomain", code: 102))
        #expect(view.presenter.state == .ready)
        view.presenter.beginLoading()
        let blockedNav = try #require(web.loadHTMLString("", baseURL: nil))
        view.webView(web, didStartProvisionalNavigation: blockedNav)
        view.presenter.fail("This comparison requires an HTTPS address.")
        view.webView(web, didFailProvisionalNavigation: blockedNav, withError: URLError(.timedOut))
        #expect(view.presenter.state == .failed("This comparison requires an HTTPS address."))
        view.presenter.beginLoading()
        let timedOut = try #require(web.loadHTMLString("", baseURL: nil))
        view.webView(web, didStartProvisionalNavigation: timedOut)
        view.webView(web, didFail: timedOut, withError: URLError(.timedOut))
        guard case .failed = view.presenter.state else {
            Issue.record("Expected the deployment timeout to appear")
            return
        }
    }

    @Test func hidingCanvasMovesFocusToStateButton() throws {
        let view = try comparison()
        defer { view.tearDown() }
        let window = SharedEvents.window(containing: view, size: CGSize(width: 1000, height: 600))
        defer { window.close() }
        view.presenter.beginLoading()
        view.presenter.setMode(.curtain)
        window.layoutIfNeeded()
        let canvas = try #require(SharedFixtures.descendants(view, of: VisualPreviewCanvas.self).first)
        let handle = try #require(
            SharedFixtures.descendants(canvas, of: NSView.self).first { $0.accessibilityRole() == .slider })
        #expect(window.makeFirstResponder(handle))
        view.presenter.fail("Preview offline")
        let retry = try #require(
            SharedFixtures.descendants(view, of: PartsButton.self).first { $0.accessibilityLabel() == "Retry" })
        #expect(window.firstResponder === retry)
    }

    @Test func curtainDragChangesClipAndHandleSynchronously() throws {
        let view = try comparison()
        defer { view.tearDown() }
        let window = SharedEvents.window(containing: view, size: CGSize(width: 1000, height: 600))
        defer { window.close() }
        view.presenter.beginLoading()
        view.presenter.setMode(.curtain)
        window.layoutIfNeeded()
        let live = view.productionWebView
        let preview = view.previewWebView
        let clip = try #require(preview.superview)
        let stage = try #require(clip.superview)
        let handle = try #require(stage.subviews.first { $0.accessibilityRole() == .slider })
        let initial = live.frame
        #expect(initial.width > 0)
        var generalUpdates = 0
        view.presenter.onChange = { generalUpdates += 1 }
        for position in [0.2, 0.75] {
            view.presenter.setCurtainPosition(position)
            let split = initial.minX + (initial.width * position).rounded()
            #expect(clip.frame.minX == split && clip.frame.maxX == initial.maxX)
            #expect(
                handle.frame.midX == split && handle.accessibilityValue() as? String == position.formatted(.percent))
            #expect(live.frame == initial && preview.convert(preview.bounds, to: live) == live.bounds)
        }
        #expect(generalUpdates == 0)
    }
}
