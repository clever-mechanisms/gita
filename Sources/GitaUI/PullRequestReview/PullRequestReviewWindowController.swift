import AppKit
import GitaCore

/// Dedicated pop-out window hosting the exact same `PullRequestReviewView` and `PullRequestReviewState` from
/// `PullRequestReviewController` without creating a second state machine or duplicate load.
@MainActor
final class PullRequestReviewWindowController: NSWindowController, NSWindowDelegate {
    private(set) weak var controller: PullRequestReviewController?
    private let hostView = ThemedBackgroundView()
    var onClose: ((PullRequestReviewView) -> Void)?

    init(controller: PullRequestReviewController, title: String) {
        self.controller = controller
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_120, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: true)
        window.minSize = NSSize(width: 720, height: 480)
        window.title = title.isEmpty ? String(localized: "Pull Request Review") : title
        window.isReleasedWhenClosed = false
        window.contentView = hostView
        window.center()
        super.init(window: window)
        window.delegate = self
        attachReviewView()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("PullRequestReviewWindowController is built in code") }

    func attachReviewView() {
        guard let reviewView = controller?.reviewView else { return }
        reviewView.removeFromSuperview()
        reviewView.setPresentation(.window)
        Style.fill(reviewView, in: hostView)
    }

    func show() {
        attachReviewView()
        if NSApp.activationPolicy() == .accessory { NSApp.setActivationPolicy(.regular) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_: Notification) {
        guard let reviewView = controller?.reviewView else { return }
        if reviewView.superview === hostView {
            reviewView.removeFromSuperview()
        }
        onClose?(reviewView)
    }
}
