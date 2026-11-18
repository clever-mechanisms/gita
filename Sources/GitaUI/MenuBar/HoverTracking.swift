import AppKit

/// The one tracking area a hover-highlighting view needs: enter and exit over its visible rect, always active.
@MainActor
enum HoverTracking {
    /// Replaces `view`'s tracking areas; with `enabled` false it only removes them.
    static func update(_ view: NSView, enabled: Bool = true) {
        for area in view.trackingAreas { view.removeTrackingArea(area) }
        guard enabled else { return }
        view.addTrackingArea(
            NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: view))
    }
}
