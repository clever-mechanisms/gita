import AppKit

/// A repository tab's or tab group's colour, chosen from the tab context menu. Raw values are saved in the tab session.
enum TabColor: String, CaseIterable, Codable {
    case red, orange, yellow, green, blue, purple, pink, grey
    private static let swatchSide: CGFloat = 12

    var localizedTitle: String {
        switch self {
        case .red: String(localized: "Red")
        case .orange: String(localized: "Orange")
        case .yellow: String(localized: "Yellow")
        case .green: String(localized: "Green")
        case .blue: String(localized: "Blue")
        case .purple: String(localized: "Purple")
        case .pink: String(localized: "Pink")
        case .grey: String(localized: "Grey")
        }
    }
    @MainActor var color: NSColor { Theme.tabColor(self) }
    /// A round swatch for menus; drawn at menu time, so it follows the appearance.
    @MainActor var swatch: NSImage {
        let color = color
        let image = NSImage(size: NSSize(width: Self.swatchSide, height: Self.swatchSide), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.accessibilityDescription = localizedTitle
        return image
    }
}
