import AppKit
import GitaCore

enum QuickLookNavigationDirection: Sendable { case previous, next }

@MainActor
final class GitaQuickLookPanelController {
    var onNavigate: ((QuickLookNavigationDirection) -> Void)?
    var onOpenFullInMainWindow: ((QuickLookTarget) -> Void)?
    var isVisible: Bool { panel?.isVisible == true }
    private(set) var panel: QuickLookPanel?
    private weak var anchorWindow: NSWindow?
    private let presenter: QuickLookPresenter

    init(presenter: QuickLookPresenter = .init()) { self.presenter = presenter }

    isolated deinit { close() }

    func toggle(for target: QuickLookTarget, relativeTo anchorWindow: NSWindow? = nil) {
        if isVisible, presenter.currentTarget == target { close() } else { show(for: target, relativeTo: anchorWindow) }
    }

    func show(for target: QuickLookTarget, relativeTo anchorWindow: NSWindow? = nil) {
        self.anchorWindow = anchorWindow
        let window = panel ?? makePanel(relativeTo: anchorWindow)
        presenter.select(target)
        window.orderFrontRegardless()
        window.makeKey()
        window.makeFirstResponder(window.contentView)
    }

    func updateSelection(_ target: QuickLookTarget) {
        guard isVisible, target != presenter.currentTarget else { return }
        presenter.select(target)
    }

    func close() {
        panel?.orderOut(nil)
        presenter.clear()
        if anchorWindow?.isVisible == true { anchorWindow?.makeKey() }
        anchorWindow = nil
    }

    private func openFull() {
        guard let target = presenter.currentTarget else { return }
        close()
        onOpenFullInMainWindow?(target)
    }

    private func makePanel(relativeTo anchor: NSWindow?) -> QuickLookPanel {
        let window = QuickLookPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 460),
            styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: true)
        window.isFloatingPanel = true
        window.level = .floating
        window.hasShadow = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hidesOnDeactivate = true
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 480, height: 340)
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.animationBehavior = Deck.reduceMotion ? .none : .utilityWindow
        window.title = String(localized: "Quick Look")
        if !window.setFrameUsingName("GitaQuickLookPanel") {
            if let anchor {
                let rect = NSRect(
                    x: anchor.frame.midX - window.frame.width / 2, y: anchor.frame.midY - window.frame.height / 2,
                    width: window.frame.width, height: window.frame.height)
                window.setFrame(window.constrainFrameRect(rect, to: anchor.screen), display: false)
            } else {
                window.center()
            }
        }
        window.setFrameAutosaveName("GitaQuickLookPanel")
        let view = QuickLookPreviewView(frame: window.frame)
        window.contentView = view
        window.onDismiss = { [weak self] in self?.close() }
        view.onClose = window.onDismiss
        view.onNavigate = { [weak self] in self?.onNavigate?($0) }
        view.onOpenFull = { [weak self] in self?.openFull() }
        view.onRetry = { [weak presenter] in presenter?.retry() }
        presenter.attach(view)
        panel = window
        return window
    }
}

@MainActor
final class QuickLookPanel: NSPanel {
    var onDismiss: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_: Any?) { onDismiss?() }
    override func performClose(_: Any?) { onDismiss?() }
}
