import AppKit

/// Scrolls only by whole device pixels. On a 1x display a trackpad scroll otherwise stops between pixels, and rows
/// drawn edge to edge (graph lines, selection) show a light seam where each row's edge is blended with the background.
final class PixelAlignedClipView: NSClipView {
    /// Used before the view is in a window: the common Retina scale.
    private static let defaultScale: CGFloat = 2

    static func aligned(_ point: NSPoint, scale: CGFloat) -> NSPoint {
        NSPoint(x: (point.x * scale).rounded() / scale, y: (point.y * scale).rounded() / scale)
    }
    private func aligned(_ point: NSPoint) -> NSPoint {
        Self.aligned(point, scale: window?.backingScaleFactor ?? Self.defaultScale)
    }
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        rect.origin = aligned(rect.origin)
        return rect
    }
    override func setBoundsOrigin(_ newOrigin: NSPoint) { super.setBoundsOrigin(aligned(newOrigin)) }
    override func scroll(to newOrigin: NSPoint) { super.scroll(to: aligned(newOrigin)) }
}
