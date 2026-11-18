import AppKit

/// The window background behind the groups.
final class SettingsBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Theme.window.setFill()
        dirtyRect.fill()
    }
    override var isFlipped: Bool { true }
}
