import AppKit
import GitaCore

@MainActor
public final class VisualPreviewDiffWindowController: NSWindowController, NSWindowDelegate {
    public let comparison: VisualPreviewDiffView
    public var onClose: (() -> Void)?

    public init(pair: VisualPreviewPair, initialRoute: String = "/") {
        let presenter = VisualPreviewDiffPresenter(
            productionURL: pair.productionURL, previewURL: pair.previewURL,
            initialRoute: initialRoute)
        comparison = VisualPreviewDiffView(presenter: presenter)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
            defer: false)
        window.title = pair.title
        window.minSize = NSSize(width: 820, height: 560)
        window.isReleasedWhenClosed = false
        window.contentView = comparison
        super.init(window: window)
        window.center()
        windowFrameAutosaveName = "GitaVisualPreviewDiffWindow"
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("Use init(pair:initialRoute:)") }

    public override func showWindow(_: Any?) {
        guard let window else { return }
        AuxiliaryWindowActivation.show(window)
        if comparison.presenter.state == .idle { comparison.reload() }
    }

    public func windowWillClose(_: Notification) {
        comparison.tearDown()
        AuxiliaryWindowActivation.closing(window)
        onClose?()
    }

    public override func cancelOperation(_: Any?) { close() }
}
