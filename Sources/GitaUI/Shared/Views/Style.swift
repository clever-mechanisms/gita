import AppKit
import GitaCore

/// Plain AppKit controls for sheets, pages and lists (system label colours, rounded buttons), and the graph's lane
/// colours. The main window surfaces use `Deck` instead.
@MainActor
enum Style {
    /// Lane colours: a darker tone in light mode (readable on white), the system colour in dark mode.
    static let graphColors: [NSColor] = [
        (0xB56500, NSColor.systemOrange), (0x007F88, .systemTeal), (0x8C3BBA, .systemPurple),
        (0x086EBC, .systemBlue), (0xBA3B70, .systemPink), (0x927000, .systemYellow), (0x327C44, .systemGreen),
    ].map { hex, dark in adaptive(light: color(hex: hex), dark: dark) }

    private static func color(hex: Int) -> NSColor {
        let channel = { (shift: Int) in CGFloat((hex >> shift) & 0xFF) / 0xFF }
        return NSColor(calibratedRed: channel(16), green: channel(8), blue: channel(0), alpha: 1)
    }
    private static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }

    static func label(
        _ text: String, size: CGFloat = 12, weight: NSFont.Weight = .regular, color: NSColor = .labelColor
    ) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = TextLines.system(size, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        return label
    }
    static func button(_ title: String, symbol: String? = nil, target: AnyObject?, action: Selector?) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        if let symbol {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            button.imagePosition = .imageLeading
        }
        button.controlSize = .small
        button.font = TextLines.system(12)
        return button
    }
    static func stack(_ views: [NSView], vertical: Bool = false, spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = vertical ? .vertical : .horizontal
        stack.alignment = vertical ? .leading : .centerY
        stack.spacing = spacing
        return stack
    }
    /// Adds `child` to `parent` and pins all four edges, `inset` in from each.
    static func fill(_ child: NSView, in parent: NSView, inset: CGFloat = 0) {
        Deck.pin(child, in: parent, insets: NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset))
    }
    static func scroll(_ view: NSView, horizontal: Bool = false) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.contentView = PixelAlignedClipView()
        scroll.documentView = view
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = horizontal
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.window
        return scroll
    }
    static func stateSymbol(_ state: SignalState) -> String {
        switch state {
        case .success: "checkmark.circle.fill"
        case .failure: "xmark.circle.fill"
        case .running: "arrow.triangle.2.circlepath"
        case .pending: "clock"
        case .cancelled: "minus.circle"
        case .neutral: "circle"
        }
    }
}
