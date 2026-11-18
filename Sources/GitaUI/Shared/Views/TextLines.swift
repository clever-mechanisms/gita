import AppKit
import CoreText

/// One-line text for drawn cells (history rows, diff lines, status chips), typeset once and reused.
///
/// `NSString.draw(in:withAttributes:)` builds an attributed string, bridges the attribute dictionary and runs the
/// typesetter on every call; in a scrolling table that is most of the main thread's time. Here a Core Text line is
/// cached per string and font, takes its colour from the context (so one line serves every appearance and theme),
/// and a truncated variant is cached per width. Placement uses the typesetter's baseline offset for the font, which
/// renders pixel-identically to `NSString.draw(in:)` for Latin, CJK, digits and monospaced text (flipped
/// and unflipped, every sub-pixel offset). Two deliberate differences: in flipped views NSString drops
/// Arabic and Hebrew lines ~2 pt below the shared baseline, here they stay on it; and a truncated line may keep one
/// glyph fewer before the ellipsis.
@MainActor
enum TextLines {
    private struct Key: Hashable {
        let text: String
        let font: NSFont // held strongly: identity is part of the key and cannot be reused while cached
        static func == (a: Self, b: Self) -> Bool { a.font === b.font && a.text == b.text }
        func hash(into hasher: inout Hasher) {
            hasher.combine(ObjectIdentifier(font))
            hasher.combine(text)
        }
    }
    private struct TruncatedKey: Hashable {
        let key: Key
        let width: Int
        func hash(into hasher: inout Hasher) {
            hasher.combine(key)
            hasher.combine(width)
        }
    }
    private struct FontKey: Hashable {
        let size: CGFloat
        let weight: CGFloat
        let monospaced: Bool
        func hash(into hasher: inout Hasher) {
            hasher.combine(size)
            hasher.combine(weight)
            hasher.combine(monospaced)
        }
    }
    private static var lines: [Key: CTLine] = [:]
    private static var truncated: [TruncatedKey: CTLine] = [:]
    private static var ellipses: [ObjectIdentifier: CTLine] = [:]
    private static var fonts: [FontKey: NSFont] = [:]
    private static var baselines: [ObjectIdentifier: (font: NSFont, offset: CGFloat)] = [:]
    private static let layoutManager = NSLayoutManager()
    /// Where NSString puts the first baseline below the top of its rect, per font.
    private static func baseline(_ font: NSFont) -> CGFloat {
        if let cached = baselines[ObjectIdentifier(font)], cached.font === font { return cached.offset }
        let offset = layoutManager.defaultBaselineOffset(for: font)
        baselines[ObjectIdentifier(font)] = (font, offset)
        return offset
    }
    private static let limit = 8_000

    /// The interface font (`InterfaceFont.current`, SF Pro by default), one shared instance per size and weight (a new
    /// instance per draw also rebuilds Core Text's per-font glyph caches).
    static func system(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        font(FontKey(size: size, weight: weight.rawValue, monospaced: false)) {
            InterfaceFont.current.make(size, weight: weight)
        }
    }
    /// The chosen code font (`CodeFont.current`), one shared instance per size and weight.
    static func monospaced(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        font(FontKey(size: size, weight: weight.rawValue, monospaced: true)) {
            CodeFont.current.make(size, weight: weight)
        }
    }
    /// Drops the monospaced instances so the next draw uses the new face (lines cached for the old one age out).
    static func codeFontChanged() {
        fonts = fonts.filter { !$0.key.monospaced }
    }
    /// True for a code-font instance handed out by `monospaced` (so an interface-font switch leaves it alone even when
    /// both settings use the same family).
    static func isCodeFont(_ font: NSFont) -> Bool { fonts.contains { $0.key.monospaced && $0.value === font } }
    /// Drops the interface-font instances (`InterfaceFont.apply`); the code font's stay.
    static func interfaceFontChanged() {
        fonts = fonts.filter { $0.key.monospaced }
    }
    private static func font(_ key: FontKey, make: () -> NSFont) -> NSFont {
        if let font = fonts[key] { return font }
        let font = make()
        fonts[key] = font
        return font
    }

    private static func line(_ key: Key) -> CTLine {
        if let line = lines[key] { return line }
        if lines.count >= limit {
            lines.removeAll(keepingCapacity: true)
            truncated.removeAll(keepingCapacity: true)
        }
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: key.font, kCTForegroundColorFromContextAttributeName: true,
        ]
        let line = CTLineCreateWithAttributedString(
            CFAttributedStringCreate(nil, key.text as CFString, attributes as CFDictionary))
        lines[key] = line
        return line
    }
    private static func ellipsis(_ font: NSFont) -> CTLine {
        if let line = ellipses[ObjectIdentifier(font)] { return line }
        let line = self.line(Key(text: "\u{2026}", font: font))
        ellipses[ObjectIdentifier(font)] = line
        return line
    }

    /// Typographic width of the whole line (what `NSString.size(withAttributes:)` reports).
    static func width(_ text: String, font: NSFont) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line(Key(text: text, font: font)), nil, nil, nil))
    }

    enum Alignment { case left, right }

    /// Draws `text` on one line inside `rect` like `NSString.draw(in:)` with a tail-truncating paragraph style.
    static func draw(_ text: String, font: NSFont, color: NSColor, in rect: NSRect, alignment: Alignment = .left) {
        guard !text.isEmpty, rect.width > 0, let context = NSGraphicsContext.current else { return }
        let key = Key(text: text, font: font)
        var drawn = line(key)
        var width = CGFloat(CTLineGetTypographicBounds(drawn, nil, nil, nil))
        if width > rect.width + 0.01 {
            let truncatedKey = TruncatedKey(key: key, width: Int((rect.width * 2).rounded(.down)))
            if let cached = truncated[truncatedKey] {
                drawn = cached
            } else if let made = CTLineCreateTruncatedLine(drawn, Double(rect.width), .end, ellipsis(font)) {
                truncated[truncatedKey] = made
                drawn = made
            } else {
                return
            }
            width = CGFloat(CTLineGetTypographicBounds(drawn, nil, nil, nil))
        }
        let x = alignment == .right ? rect.maxX - width : rect.minX
        render(drawn, font: font, color: color, x: x, top: context.isFlipped ? rect.minY : rect.maxY, context: context)
    }

    /// Draws `text` untruncated with its top-left at `point`, like `NSString.draw(at:)` in a flipped view (all drawn
    /// cells are flipped; an unflipped context falls back to NSString).
    static func draw(_ text: String, font: NSFont, color: NSColor, at point: NSPoint) {
        guard !text.isEmpty, let context = NSGraphicsContext.current else { return }
        guard context.isFlipped else {
            NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]).draw(at: point)
            return
        }
        render(line(Key(text: text, font: font)), font: font, color: color, x: point.x, top: point.y, context: context)
    }

    private static func render(
        _ line: CTLine, font: NSFont, color: NSColor, x: CGFloat, top: CGFloat, context: NSGraphicsContext
    ) {
        let cg = context.cgContext
        cg.saveGState()
        cg.setFillColor(color.cgColor)
        let offset = baseline(font)
        if context.isFlipped {
            cg.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            cg.textPosition = CGPoint(x: x, y: top + offset)
        } else {
            cg.textMatrix = .identity
            cg.textPosition = CGPoint(x: x, y: top - offset)
        }
        CTLineDraw(line, cg)
        cg.restoreGState()
    }
}
