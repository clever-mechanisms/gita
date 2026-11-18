import AppKit

extension NSView {
    /// Replaces the view's tracking areas with one that reports the mouse entering and leaving its visible bounds
    /// while the window is key. Call from `updateTrackingAreas()` after `super`.
    func replaceHoverTrackingArea() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
}
