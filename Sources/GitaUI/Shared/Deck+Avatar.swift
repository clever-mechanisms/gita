import AppKit

/// Author avatars (author column, commit header): the GitHub picture, or initials in the author's colour.
extension Deck {
    private static var initialsCache: [String: String] = [:]
    private static let initialsCacheLimit = 2_000
    static func initials(_ name: String) -> String {
        if let cached = initialsCache[name] { return cached }
        let value = computeInitials(name)
        if initialsCache.count > initialsCacheLimit { initialsCache.removeAll() }
        initialsCache[name] = value
        return value
    }
    /// The first letters of the first and last words ("Ada Lovelace" → "AL"), else the first two of the only word.
    static func computeInitials(_ name: String) -> String {
        let words = name.split(whereSeparator: { " -_.".contains($0) }).filter { $0.first?.isLetter == true }
        if words.count >= 2, let first = words.first?.first, let last = words.last?.first {
            return String([first, last]).uppercased()
        }
        return String(words.first?.prefix(2) ?? name.prefix(1)).uppercased()
    }

    private struct AvatarKey: Hashable {
        var photo: ObjectIdentifier?
        var initials: String
        var tint: Int
        var width: CGFloat
        var height: CGFloat
        var dark: Bool
        // Written out: the dead-code scan does not count a synthesized conformance as reading the parts.
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.photo == rhs.photo && lhs.initials == rhs.initials && lhs.tint == rhs.tint && lhs.width == rhs.width
                && lhs.height == rhs.height && lhs.dark == rhs.dark
        }
        func hash(into hasher: inout Hasher) {
            hasher.combine(photo)
            hasher.combine(initials)
            hasher.combine(tint)
            hasher.combine(width)
            hasher.combine(height)
            hasher.combine(dark)
        }
    }
    private static var avatarImages: [AvatarKey: NSImage] = [:]
    private static let avatarCacheLimit = 1_024

    /// The author's GitHub picture when `AvatarStore` has one, otherwise initials in the author's own colour
    /// (`Theme.authorColors`, the same person always the same colour); both ringed in that colour. In the graph
    /// (`lane`) the avatar takes the lane's colour and no ring of its own: the node's lane ring is its border.
    /// Draws a finished avatar from a cache (per picture or initials, size and appearance): history rows redraw it
    /// on every scroll, and re-typesetting initials or downsampling a full-size photo each time is wasted work.
    static func drawAvatar(_ name: String, email: String = "", in rect: NSRect, lane: Int? = nil) {
        let photo = AvatarStore.shared.image(email: email)
        let dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        // A negative tint names a lane.
        let tint = lane.map { -1 - abs($0) % Style.graphColors.count } ?? Theme.authorColorIndex(name)
        let key = AvatarKey(
            photo: photo.map(ObjectIdentifier.init), initials: photo == nil ? initials(name) : "", tint: tint,
            width: rect.width, height: rect.height, dark: dark)
        let image = avatarImages[key] ?? renderAvatar(name, photo: photo, tint: tint, size: rect.size, dark: dark)
        if avatarImages[key] == nil {
            if avatarImages.count > avatarCacheLimit { avatarImages.removeAll(keepingCapacity: true) }
            avatarImages[key] = image
        }
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
    private static func renderAvatar(
        _ name: String, photo: NSImage?, tint: Int, size: NSSize, dark: Bool
    ) -> NSImage {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        return NSImage(size: size, flipped: false) { bounds in
            // Resolved under the appearance the cache key names, whenever AppKit renders a representation.
            MainActor.assumeIsolated {
                if let appearance {
                    appearance.performAsCurrentDrawingAppearance {
                        drawAvatarUncached(name, photo: photo, tint: tint, in: bounds)
                    }
                } else {
                    drawAvatarUncached(name, photo: photo, tint: tint, in: bounds)
                }
            }
            return true
        }
    }
    /// Theme or accent changed: cached renderings used the old colours.
    static func themeChanged() { avatarImages.removeAll() }

    private static func drawAvatarUncached(_ name: String, photo: NSImage?, tint: Int, in rect: NSRect) {
        let inGraph = tint < 0
        let color = inGraph ? Style.graphColors[-1 - tint] : Theme.authorColors[tint]
        let ringWidth: CGFloat = inGraph ? 0 : rect.height >= 20 ? 1.25 : 1
        let ring = NSBezierPath(ovalIn: rect.insetBy(dx: ringWidth / 2, dy: ringWidth / 2))
        ring.lineWidth = ringWidth
        if let photo {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(ovalIn: rect).addClip()
            photo.draw(
                in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high.rawValue])
            NSGraphicsContext.restoreGraphicsState()
            if !inGraph {
                color.withAlphaComponent(0.85).setStroke()
                ring.stroke()
            }
            return
        }
        Theme.window.setFill()
        NSBezierPath(ovalIn: rect).fill() // opaque base: the tint reads the same on any row
        color.withAlphaComponent(0.18).setFill()
        NSBezierPath(ovalIn: rect).fill()
        if !inGraph {
            color.withAlphaComponent(0.7).setStroke()
            ring.stroke()
        }
        drawInitials(name, color: color, in: rect)
    }
    private static func drawInitials(_ name: String, color: NSColor, in rect: NSRect) {
        let font = TextLines.system(max(7, rect.height * 0.5), weight: .bold)
        let text = NSAttributedString(string: initials(name), attributes: [.font: font, .foregroundColor: color])
        let size = text.size()
        text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }
}
