import AppKit

/// The menu bar icon: the code-drawn guitar glyph (the app icon's guitar, as a line drawing), then the number of
/// working agents and an orange attention dot when the user enabled them (Settings ▸ Menu Bar). Cached per look and
/// redrawn only when the look changes.
@MainActor
enum MenuIcon {
    struct Look: Hashable {
        var count: Int?
        var dot: Bool
    }
    private static var cache: [Look: NSImage] = [:]
    static let height: CGFloat = 18
    private static let glyphWidth: CGFloat = 18
    private static let countGap: CGFloat = 2
    private static let dotGap: CGFloat = 4
    private static let dotSize: CGFloat = 6
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)

    static func width(for look: Look, textWidth: CGFloat) -> CGFloat {
        var width = glyphWidth
        if look.count != nil { width += countGap + textWidth }
        if look.dot { width += dotGap + dotSize }
        return width + (look.count != nil || look.dot ? 1 : 0)
    }

    static func image(for look: Look) -> NSImage {
        if let cached = cache[look] { return cached }
        let text = look.count.map { "\($0)" }
        let textWidth = text.map { ceil(NSAttributedString(string: $0, attributes: [.font: font]).size().width) } ?? 0
        let size = NSSize(width: width(for: look, textWidth: textWidth), height: height)
        let image = NSImage(size: size, flipped: false) { _ in
            draw(look, text: text, textWidth: textWidth)
            return true
        }
        image.isTemplate = !look.dot
        image.cacheMode = look.dot ? .never : .default
        image.accessibilityDescription = "Gitā"
        cache[look] = image
        return image
    }

    /// Template looks draw in black (the menu bar tints them); the attention look carries its own orange, so it
    /// resolves the glyph colour from the menu bar's appearance at draw time.
    private static func draw(_ look: Look, text: String?, textWidth: CGFloat) {
        let appearance = NSAppearance.currentDrawing()
        let dark =
            appearance.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark]).map {
                $0 == .darkAqua || $0 == .vibrantDark
            } ?? false
        let ink: NSColor = look.dot ? (dark ? .white : NSColor.black.withAlphaComponent(0.85)) : .black
        drawGlyph(ink)
        var x = glyphWidth
        if let text {
            x += countGap
            let lineHeight = font.ascender - font.descender
            NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: ink])
                .draw(at: NSPoint(x: x, y: ((height - lineHeight) / 2).rounded()))
            x += textWidth
        }
        if look.dot {
            x += dotGap
            appearance.performAsCurrentDrawingAppearance { Theme.needsInput.setFill() }
            NSBezierPath(ovalIn: NSRect(x: x, y: (height - dotSize) / 2, width: dotSize, height: dotSize)).fill()
        }
    }

    /// The app icon's guitar as a line drawing: the body's outline, the neck and headstock with a tuning peg on each
    /// side, and the branch graph on the body (three nodes, the neck running into the top one). It is built upright
    /// around the body's centre, then turned 45° so the neck points up and to the right, as on the app icon. The
    /// media kit's `icon-kit/menubar` exports the same geometry.
    static func drawGlyph(_ ink: NSColor) {
        ink.setStroke()
        ink.setFill()
        let transform = glyphTransform
        let outline = guitarOutline()
        outline.transform(using: transform)
        outline.lineWidth = 1.3
        outline.stroke()
        let graph = NSBezierPath()
        graph.move(to: NSPoint(x: 0, y: 4.8))
        graph.line(to: Glyph.top)
        graph.curve(to: Glyph.left, controlPoint1: NSPoint(x: -0.7, y: 0.6), controlPoint2: NSPoint(x: -1.3, y: -0.7))
        graph.move(to: Glyph.top)
        graph.curve(to: Glyph.bottom, controlPoint1: NSPoint(x: -0.1, y: 0), controlPoint2: NSPoint(x: 0.4, y: -1.7))
        graph.transform(using: transform)
        graph.lineWidth = 0.9
        graph.lineCapStyle = .round
        graph.stroke()
        let solid = NSBezierPath()
        solid.append(
            NSBezierPath(roundedRect: NSRect(x: -0.8, y: 4.6, width: 1.6, height: 5.6), xRadius: 0.5, yRadius: 0.5))
        solid.append(
            NSBezierPath(roundedRect: NSRect(x: -1.3, y: 9.6, width: 2.6, height: 3.4), xRadius: 0.9, yRadius: 0.9))
        for (center, radius) in [(NSPoint(x: -2.1, y: 11.6), 0.75), (NSPoint(x: 2.1, y: 11), 0.75)]
            + [Glyph.top, Glyph.left, Glyph.bottom].map({ ($0, 1.2) })
        {
            solid.append(
                NSBezierPath(
                    ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)))
        }
        solid.transform(using: transform)
        solid.fill()
    }

    /// The branch graph's nodes, in the upright guitar's coordinates.
    private enum Glyph {
        static let top = NSPoint(x: 0.1, y: 1.5)
        static let left = NSPoint(x: -2, y: -0.8)
        static let bottom = NSPoint(x: 0.4, y: -3.5)
    }

    /// Upright → the 18-point glyph box: centred, a little smaller, turned 45° clockwise.
    private static var glyphTransform: AffineTransform {
        var transform = AffineTransform(translationByX: 7.3, byY: 7.1)
        transform.scale(0.84)
        transform.rotate(byDegrees: -45)
        return transform
    }

    /// The body: a wide lower bout, a waist and a narrower upper bout, mirrored on the neck's axis.
    private static func guitarOutline() -> NSBezierPath {
        // The right half from the bottom up: each curve's end point and its two control points.
        let right: [(NSPoint, NSPoint, NSPoint)] = [
            (NSPoint(x: 4.5, y: -2.7), NSPoint(x: 2.6, y: -6), NSPoint(x: 4.5, y: -4.7)),
            (NSPoint(x: 2.9, y: 0.7), NSPoint(x: 4.5, y: -0.9), NSPoint(x: 2.9, y: -0.5)),
            (NSPoint(x: 3.6, y: 2.9), NSPoint(x: 2.9, y: 1.4), NSPoint(x: 3.6, y: 1.8)),
            (NSPoint(x: 0, y: 5.3), NSPoint(x: 3.6, y: 4.4), NSPoint(x: 2, y: 5.3)),
        ]
        let mirror = { (point: NSPoint) in NSPoint(x: -point.x, y: point.y) }
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: -6))
        for segment in right { path.curve(to: segment.0, controlPoint1: segment.1, controlPoint2: segment.2) }
        // Back down the left half: the same curves mirrored, in reverse, with their control points swapped.
        let starts = [NSPoint(x: 0, y: -6)] + right.map(\.0)
        for index in right.indices.reversed() {
            let segment = right[index]
            path.curve(
                to: mirror(starts[index]), controlPoint1: mirror(segment.2), controlPoint2: mirror(segment.1))
        }
        path.close()
        return path
    }
}
