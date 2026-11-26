import AppKit

/// A borderless, non-activating panel under the status item: opaque, 12 pt corners, a hairline border and a shadow.
/// Keyboard focus without stealing activation from the app you're in; closes on Escape (which first goes back from
/// the Activity page), an outside click or losing key.
@MainActor
final class MenuPanelWindow: NSPanel {
    private let container = PanelContainerView()
    private var monitor: Any?
    private weak var anchor: NSStatusBarButton?
    var onClose: (() -> Void)?
    /// Escape, before it closes the panel: true when the panel's content used it (to go back a page).
    private var onCancel: () -> Bool = { false }
    private(set) var isShown = false
    /// Gap between the status item and the panel, and the panel and the screen edges.
    private static let drop: CGFloat = 6
    private static let screenMargin: CGFloat = 8

    init(controller: MenuPanelController) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Theme.panelWidth, height: 300),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = Deck.reduceMotion ? .none : .utilityWindow
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        contentView = container
        container.addSubview(controller.view)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: container.topAnchor),
            controller.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            controller.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        controller.onSizeChange = { [weak self] size in self?.resize(to: size) }
        onCancel = { [weak controller] in controller?.back() ?? false }
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func show(below button: NSStatusBarButton, size: NSSize) {
        anchor = button
        resize(to: size)
        orderFrontRegardless()
        makeKey()
        isShown = true
        button.highlight(true)
        let close: (NSEvent) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.performClose(nil) } }
        monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: close)
    }

    private func resize(to size: NSSize) {
        guard let button = anchor, let buttonWindow = button.window else {
            setContentSize(size)
            return
        }
        let item = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen =
            (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_440, height: 900)
        setFrame(Self.frame(size: size, below: item, in: screen), display: true)
    }

    /// Centred under the status item, kept inside the screen's visible frame.
    static func frame(size: NSSize, below item: NSRect, in screen: NSRect) -> NSRect {
        let centred = (item.midX - size.width / 2).rounded()
        let x = max(screen.minX + screenMargin, min(centred, screen.maxX - size.width - screenMargin))
        return NSRect(x: x, y: item.minY - drop - size.height, width: size.width, height: size.height)
    }

    override func performClose(_: Any?) {
        guard isShown else { return }
        isShown = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        anchor?.highlight(false)
        orderOut(nil)
        onClose?()
    }
    override func resignKey() {
        super.resignKey()
        if isShown { performClose(nil) }
    }
    override func cancelOperation(_: Any?) { if !onCancel() { performClose(nil) } }
}

/// Rounded, bordered and opaque in the theme's window colour.
@MainActor
private final class PanelContainerView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
    }
    @available(*, unavailable, message: "The panel container is built in code")
    required init?(coder _: NSCoder) { fatalError("The panel container is built in code") }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = Theme.window.cgColor
        layer?.borderColor = Theme.separator.cgColor
    }
}
