import AppKit

/// Symbol glyphs in drawn cells.
@MainActor
enum GlyphDrawing {
    /// Draws `image` at its own size, centred on `box` and pixel-aligned.
    static func drawCentered(_ image: NSImage, in box: NSRect) {
        image.draw(
            in: NSRect(
                x: (box.midX - image.size.width / 2).rounded(), y: (box.midY - image.size.height / 2).rounded(),
                width: image.size.width, height: image.size.height),
            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
