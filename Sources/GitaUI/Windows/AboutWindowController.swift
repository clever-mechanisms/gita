import AppKit

/// About Gita: icon, name, version (build) and one line; "This copy" beside "Links"; the copyright. App menu ▸
/// About Gita calls `show()`.
@MainActor
final class AboutWindowController: NSWindowController, NSWindowDelegate {
    static let shared = AboutWindowController()
    convenience init() { self.init(window: nil) }

    func show() {
        let window = prepareWindow()
        if !window.isVisible { window.center() }
        AuxiliaryWindowActivation.show(window)
    }

    func windowWillClose(_: Notification) { AuxiliaryWindowActivation.closing(window) }

    /// The window, built once and sized to its content; not shown.
    @discardableResult func prepareWindow() -> NSWindow {
        if let window { return window }
        let view = AboutView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: AboutView.width, height: AboutView.minimumHeight),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = String(localized: "About Gitā")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = Theme.window
        window.tabbingMode = .disallowed
        window.contentView = view
        self.window = window
        window.delegate = self
        view.layoutSubtreeIfNeeded()
        window.setContentSize(
            NSSize(width: AboutView.width, height: max(AboutView.minimumHeight, view.fittingSize.height)))
        return window
    }
}
