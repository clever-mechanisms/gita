import AppKit
import GitaCore

/// Where an agent used to be named ("Claude Code · Working"), its mark now stands in for the name ("✳ Working").
/// The name stays in tooltips, menus, notifications and VoiceOver. Shapes: `AgentMarkPainter`.
@MainActor
enum AgentMarks {
    static func kind(_ tool: AgentTool) -> AgentMarkPainter.Kind {
        switch tool {
        case .claudeCode: .claude
        case .codex: .openAI
        case .gemini: .gemini
        case .cursorAgent: .cursor
        case .opencode: .opencode
        case .aider: .aider
        }
    }

    /// Draws the mark into `rect` of the current context; `flipped` for views whose y axis points down.
    static func draw(_ tool: AgentTool, in rect: NSRect, flipped: Bool) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        if flipped {
            context.translateBy(x: 0, y: rect.minY * 2 + rect.height)
            context.scaleBy(x: 1, y: -1)
        }
        AgentMarkPainter.draw(kind(tool), in: rect, context: context, ink: Theme.text.cgColor)
    }

    private static var images: [String: NSImage] = [:]
    private static let imageLimit = 128
    /// The mark as an image for image views and text attachments. It is redrawn every time it is shown
    /// (`cacheMode = .never`), so the monochrome marks follow the appearance and theme of the view showing them.
    static func image(_ tool: AgentTool, size: CGFloat) -> NSImage {
        let key = "\(tool.rawValue)|\(size)"
        if let image = images[key] { return image }
        if images.count >= imageLimit { images.removeAll() }
        let kind = kind(tool)
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let ink = MainActor.assumeIsolated { Theme.text.cgColor }
            AgentMarkPainter.draw(kind, in: rect, context: context, ink: ink)
            return true
        }
        image.cacheMode = .never
        image.accessibilityDescription = tool.displayName
        images[key] = image
        return image
    }

    /// The mark inline in a label, centred on the font's capitals, followed by a space.
    static func inline(_ tool: AgentTool, font: NSFont) -> NSMutableAttributedString {
        let side = (font.capHeight + 5).rounded()
        let attachment = NSTextAttachment()
        attachment.image = image(tool, size: side)
        attachment.bounds = NSRect(x: 0, y: ((font.capHeight - side) / 2).rounded(), width: side, height: side)
        let text = NSMutableAttributedString(attachment: attachment)
        text.append(NSAttributedString(string: " ", attributes: [.font: font]))
        return text
    }

    /// "✳ Working" for a label: the mark, then `text` in `font` and `color`.
    static func label(_ tool: AgentTool, _ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let value = inline(tool, font: font)
        value.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        return value
    }
}
