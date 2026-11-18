import AppKit

/// A small preview of a theme in an appearance: its window surface, sidebar and accent.
@MainActor
enum ThemeSwatch {
    static let size = NSSize(width: 28, height: 14)

    static func image(_ choice: Theme.Choice, dark: Bool) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            let shape = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3.5, yRadius: 3.5)
            shape.addClip()
            Theme.resolve(.window, dark: dark, choice: choice).setFill()
            rect.fill()
            Theme.resolve(.sidebar, dark: dark, choice: choice).setFill()
            NSRect(x: 0, y: 0, width: 9, height: rect.height).fill()
            Theme.resolve(.accent, dark: dark, choice: choice).setFill()
            NSBezierPath(ovalIn: NSRect(x: 14, y: 4, width: 6, height: 6)).fill()
            Theme.resolve(.separator, dark: dark, choice: choice).setStroke()
            shape.lineWidth = 1
            shape.stroke()
            return true
        }
    }
    /// The swatch in the app's current appearance.
    static func image(_ choice: Theme.Choice) -> NSImage {
        image(choice, dark: NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    }
}
