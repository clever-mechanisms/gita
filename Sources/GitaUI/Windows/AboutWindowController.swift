import AppKit

/// About Gitā standalone window: hosts the shared `AboutContentView`. App menu ▸ About Gitā calls `show()`.
@MainActor
final class AboutWindowController: NSWindowController, NSWindowDelegate {
    static let shared = AboutWindowController()
    static let width: CGFloat = 560
    private static let horizontalMargin: CGFloat = 22
    private static let topInset: CGFloat = 34
    private static let bottomMargin: CGFloat = 22

    private let configuration: AboutConfiguration
    private(set) var aboutContentView: AboutContentView?

    init(configuration: AboutConfiguration = AboutConfiguration()) {
        self.configuration = configuration
        super.init(window: nil)
    }

    @available(*, unavailable, message: "AboutWindowController is built in code")
    required init?(coder _: NSCoder) { fatalError("AboutWindowController is built in code") }

    func show() {
        let window = prepareWindow()
        aboutContentView?.refresh()
        if !window.isVisible { window.center() }
        AuxiliaryWindowActivation.show(window)
    }

    func windowWillClose(_: Notification) { AuxiliaryWindowActivation.closing(window) }

    /// The window, built once and sized to its content; not shown.
    @discardableResult func prepareWindow() -> NSWindow {
        if let window { return window }
        let content = AboutContentView(configuration: configuration)
        aboutContentView = content
        let container = AboutWindowContainer(content: content, width: Self.width)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 100),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = String(localized: "About Gitā")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = Theme.window
        window.tabbingMode = .disallowed
        window.contentView = container
        self.window = window
        window.delegate = self
        container.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: Self.width, height: max(120, container.fittingSize.height)))
        return window
    }

    private final class AboutWindowContainer: NSView {
        init(content: AboutContentView, width: CGFloat) {
            super.init(frame: NSRect(x: 0, y: 0, width: width, height: 100))
            addSubview(content)
            NSLayoutConstraint.activate([
                widthAnchor.constraint(equalToConstant: width),
                content.topAnchor.constraint(equalTo: topAnchor, constant: AboutWindowController.topInset),
                content.leadingAnchor.constraint(
                    equalTo: leadingAnchor, constant: AboutWindowController.horizontalMargin),
                content.trailingAnchor.constraint(
                    equalTo: trailingAnchor, constant: -AboutWindowController.horizontalMargin),
                content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -AboutWindowController.bottomMargin),
            ])
        }

        @available(*, unavailable, message: "AboutWindowContainer is built in code")
        required init?(coder _: NSCoder) { fatalError("AboutWindowContainer is built in code") }

        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            Theme.window.setFill()
            dirtyRect.fill()
        }
    }
}
