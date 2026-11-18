import AppKit
import GitaCore

/// The menu bar scene: Gitā's guitar with the number of working agents, its panel opening, then a notification
/// when an agent needs input.
extension SetupScenes {
    private static let menuBarHeight: CGFloat = 24

    /// How far the panel is open at `frame`: it opens on step 1 and closes on step 2.
    static func panelOpening(_ frame: Frame) -> CGFloat {
        switch frame.step {
        case 1: frame.progress
        case 2: 1 - frame.progress
        default: 0
        }
    }
    /// How far the notification is in at `frame`: it slides in on step 2 and leaves on step 0.
    static func notificationShowing(_ frame: Frame) -> CGFloat {
        switch frame.step {
        case 2: frame.progress
        case 0: 1 - frame.progress
        default: 0
        }
    }

    static func drawMenuBar(_ frame: Frame) {
        let rect = frame.rect
        let bar = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: menuBarHeight)
        Theme.toolbar.setFill()
        NSBezierPath(roundedRect: bar, xRadius: 6, yRadius: 6).fill()
        if rect.width > 420 {
            text(
                "Gitā    "
                    + [String(localized: "File"), String(localized: "Edit"), String(localized: "View")].joined(
                        separator: "    "), at: NSPoint(x: bar.minX + 12, y: bar.minY + 5), font: Theme.captionEmphasis,
                color: Theme.text)
        }
        let open = panelOpening(frame)
        let notice = notificationShowing(frame)
        let icon = statusItem(in: bar, open: open, attention: notice)
        if open > 0.01 {
            let width = min(260, rect.width - 16)
            let panel = NSRect(
                x: max(rect.minX, min(icon.maxX + 40, bar.maxX) - width), y: bar.maxY + 6, width: width,
                height: (rect.height - menuBarHeight - 6) * open)
            drawPanel(panel, alpha: open)
        }
        if notice > 0.01 {
            let width = min(280, rect.width - 16)
            drawNotification(
                NSRect(x: bar.maxX - width, y: bar.maxY + 8 - 10 * (1 - notice), width: width, height: 50),
                alpha: notice)
        }
    }

    /// The right of the menu bar: the clock, battery and Wi-Fi, then Gitā's guitar with its count and, while
    /// something needs attention, the orange dot. Returns the guitar's item.
    private static func statusItem(in bar: NSRect, open: CGFloat, attention: CGFloat) -> NSRect {
        var x = bar.maxX - 10 - textWidth("9:41", font: Theme.captionEmphasis)
        text("9:41", at: NSPoint(x: x, y: bar.minY + 5), font: Theme.captionEmphasis, color: Theme.text)
        for (symbol, width) in [("battery.75", 20), ("wifi", 16)] as [(String, CGFloat)] {
            x -= width + 10
            Deck.symbol(symbol, size: 11, color: Theme.text)?.draw(
                in: NSRect(x: x, y: bar.minY + 6, width: width, height: 12), from: .zero, operation: .sourceOver,
                fraction: 1, respectFlipped: true, hints: nil)
        }
        let count = "2"
        let countFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let countWidth = textWidth(count, font: countFont)
        let item = NSRect(
            x: x - 14 - (18 + 2 + countWidth + 10), y: bar.minY + 2, width: 18 + 2 + countWidth + 10, height: 20)
        if open > 0.01 {
            Theme.accent.withAlphaComponent(0.25 * open).setFill()
            NSBezierPath(roundedRect: item.insetBy(dx: -4, dy: 0), xRadius: 4, yRadius: 4).fill()
        }
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext.current?.cgContext
        context?.translateBy(x: item.minX, y: item.minY + 19)
        context?.scaleBy(x: 1, y: -1)
        MenuIcon.drawGlyph(Theme.text)
        NSGraphicsContext.restoreGraphicsState()
        text(count, at: NSPoint(x: item.minX + 20, y: bar.minY + 4), font: countFont, color: Theme.text)
        if attention > 0.01 {
            Theme.needsInput.withAlphaComponent(attention).setFill()
            NSBezierPath(ovalIn: NSRect(x: item.minX + 24 + countWidth, y: bar.midY - 3, width: 6, height: 6)).fill()
        }
        return item
    }

    private static func drawPanel(_ rect: NSRect, alpha: CGFloat) {
        let shape = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        Theme.window.withAlphaComponent(alpha).setFill()
        shape.fill()
        Theme.separator.withAlphaComponent(alpha).setStroke()
        shape.stroke()
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        let lines: [(String, String, NSColor)] = [
            ("gita-app", "main · " + String(localized: "2 agents working"), Theme.running),
            ("Claude Code", "feature/navigation · " + WindowAgents.stateTitle(.working), Theme.running),
            (String(localized: "Checks passed"), "main · 2m", Theme.success),
            (String(localized: "Preview ready"), "feature/navigation", Theme.success),
        ]
        for (index, line) in lines.enumerated() {
            let y = rect.minY + 8 + CGFloat(index) * 34
            node(NSPoint(x: rect.minX + 16, y: y + 9), color: line.2, alpha: alpha)
            text(
                line.0, at: NSPoint(x: rect.minX + 30, y: y), font: Theme.bodyEmphasis, color: Theme.text,
                alpha: alpha, width: rect.width - 40)
            text(
                line.1, at: NSPoint(x: rect.minX + 30, y: y + 15), font: Theme.caption, color: Theme.secondaryText,
                alpha: alpha, width: rect.width - 40)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A notification banner, as macOS shows Gitā's: the app's icon, what happened and where.
    private static func drawNotification(_ rect: NSRect, alpha: CGFloat) {
        let shape = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
        Theme.window.withAlphaComponent(alpha).setFill()
        shape.fill()
        Theme.separator.withAlphaComponent(alpha).setStroke()
        shape.stroke()
        NSApp.applicationIconImage?.draw(
            in: NSRect(x: rect.minX + 10, y: rect.minY + 10, width: 30, height: 30), from: .zero,
            operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
        let now = String(localized: "now")
        let nowWidth = textWidth(now, font: Theme.caption)
        text(
            now, at: NSPoint(x: rect.maxX - 10 - nowWidth, y: rect.minY + 8), font: Theme.caption,
            color: Theme.secondaryText, alpha: alpha)
        text(
            String(localized: "Claude Code needs input"), at: NSPoint(x: rect.minX + 48, y: rect.minY + 8),
            font: Theme.bodyEmphasis, color: Theme.text, alpha: alpha, width: rect.width - 66 - nowWidth)
        text(
            "gita-app · feature/navigation", at: NSPoint(x: rect.minX + 48, y: rect.minY + 26), font: Theme.caption,
            color: Theme.secondaryText, alpha: alpha, width: rect.width - 58)
    }
}
