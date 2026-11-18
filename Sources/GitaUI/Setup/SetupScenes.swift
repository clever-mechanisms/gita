import AppKit
import GitaCore

/// What `SetupStageView` draws: one small, fictional scene (`SetupScene`), from its step, how far the move into it
/// has come and the drafted choices. Drawing only; nothing is read. A flipped context (y down) is assumed.
@MainActor
enum SetupScenes {
    private static let radius: CGFloat = 12
    static let laneGap: CGFloat = 18
    static let nodeRadius: CGFloat = 4.5

    /// One frame of a scene.
    struct Frame {
        var scene: SetupScene
        var step: Int
        /// The eased move into `step`, 0…1.
        var progress: CGFloat
        var choices: SetupChoices
        var rect: NSRect
    }

    static func draw(_ frame: Frame) {
        switch frame.scene {
        case .history: drawHistory(frame)
        case .pullRequests: drawStatus(frame, compact: true)
        case .status: drawStatus(frame, compact: false)
        case .agents: drawAgents(frame)
        case .menuBar: drawMenuBar(frame)
        case .details: drawDetails(frame)
        case .zoom: drawZoom(frame)
        case .collapse, .squash: drawMerge(frame)
        }
    }

    /// The scene's card: a soft gradient from the inset surface to the window's, with a hairline border.
    static func panel(_ bounds: NSRect) {
        let shape = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        NSGradient(starting: Theme.inset, ending: Theme.window)?.draw(in: shape, angle: -90)
        Theme.separator.setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }

    // MARK: Pieces

    static func lane(_ index: Int) -> NSColor { Style.graphColors[index % Style.graphColors.count] }

    static func laneX(_ lane: Int, in rect: NSRect) -> CGFloat { rect.minX + 10 + CGFloat(lane) * laneGap }

    /// Draws `text` with its top-left at `point`; returns its width.
    @discardableResult
    static func text(
        _ text: String, at point: NSPoint, font: NSFont, color: NSColor, alpha: CGFloat = 1, width: CGFloat? = nil
    ) -> CGFloat {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let string = NSAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: color.withAlphaComponent(alpha), .paragraphStyle: style])
        let size = string.size()
        string.draw(in: NSRect(x: point.x, y: point.y, width: width ?? ceil(size.width) + 1, height: ceil(size.height)))
        return min(size.width, width ?? size.width)
    }

    static func node(_ center: NSPoint, color: NSColor, alpha: CGFloat = 1, hollow: Bool = false) {
        let dot = NSBezierPath(
            ovalIn: NSRect(
                x: center.x - nodeRadius, y: center.y - nodeRadius, width: nodeRadius * 2, height: nodeRadius * 2))
        Theme.window.withAlphaComponent(alpha).setFill()
        dot.fill()
        color.withAlphaComponent(alpha).set()
        dot.lineWidth = 2
        if hollow { dot.stroke() } else { dot.fill() }
    }

    /// A lane line from `start` to `end`: straight on one lane, a smooth bend between two.
    static func edge(from start: NSPoint, to end: NSPoint, color: NSColor, alpha: CGFloat = 1) {
        let path = NSBezierPath()
        path.lineWidth = 2
        path.lineCapStyle = .round
        path.move(to: start)
        if abs(start.x - end.x) < 0.5 {
            path.line(to: end)
        } else {
            let middle = (start.y + end.y) / 2
            path.curve(
                to: end, controlPoint1: NSPoint(x: start.x, y: middle), controlPoint2: NSPoint(x: end.x, y: middle))
        }
        color.withAlphaComponent(alpha).setStroke()
        path.stroke()
    }

    /// A rounded label: an optional image, then the text, tinted with `color`; returns its width.
    @discardableResult
    static func pill(
        _ title: String, at point: NSPoint, color: NSColor, image: NSImage? = nil, alpha: CGFloat = 1
    ) -> CGFloat {
        let font = Theme.captionEmphasis
        let imageWidth: CGFloat = image == nil ? 0 : 14
        let rect = NSRect(x: point.x, y: point.y, width: pillWidth(title, image: image != nil), height: 18)
        let shape = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        color.withAlphaComponent(0.16 * alpha).setFill()
        shape.fill()
        color.withAlphaComponent(0.45 * alpha).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        image?.draw(
            in: NSRect(x: rect.minX + 6, y: rect.minY + 3, width: 11, height: 11), from: .zero, operation: .sourceOver,
            fraction: alpha, respectFlipped: true, hints: nil)
        text(
            title, at: NSPoint(x: rect.minX + 7 + imageWidth, y: rect.minY + 2), font: font, color: color, alpha: alpha)
        return rect.width
    }

    /// How wide `pill` draws `title`.
    static func pillWidth(_ title: String, image: Bool) -> CGFloat {
        textWidth(title, font: Theme.captionEmphasis) + (image ? 14 : 0) + 14
    }

    /// How wide `text` draws in `font`, rounded up.
    static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil(NSAttributedString(string: text, attributes: [.font: font]).size().width)
    }

    // MARK: Settings played off and on

    /// How far the scene's setting is drawn on at `frame`, 0…1: it starts on the drafted value, then shows the other.
    static func amount(_ frame: Frame) -> CGFloat {
        let target: CGFloat = isOn(frame) ? 1 : 0
        return (1 - target) + (2 * target - 1) * frame.progress
    }
    /// The state the scene shows (or moves into) at `frame`.
    static func isOn(_ frame: Frame) -> Bool {
        guard let preference = frame.scene.preference else { return true }
        return (frame.step % 2 == 0) == frame.choices[preference]
    }

    /// The On/Off tag at the top right of a scene that plays a setting.
    static func stateTag(_ isOn: Bool, in rect: NSRect) {
        let tag = isOn ? String(localized: "On") : String(localized: "Off")
        pill(
            tag, at: NSPoint(x: rect.maxX - pillWidth(tag, image: false), y: rect.minY),
            color: isOn ? Theme.accentText : Theme.secondaryText)
    }

    // MARK: The sample history

    /// The fictional repository the scenes share: a branch in progress, a merged pull request with its branch, and
    /// the release they grew from.
    static var sampleHistory: [SceneGraph.Commit] {
        [
            SceneGraph.Commit(
                id: "navigation", subject: String(localized: "Polish repository navigation"), parents: ["tabs"],
                labels: ["navigation"], isHead: true),
            SceneGraph.Commit(
                id: "tabs", subject: String(localized: "Keyboard shortcuts for tabs"), parents: ["pull-request"]),
            SceneGraph.Commit(
                id: "pull-request", subject: String(localized: "Merge pull request #22"),
                parents: ["sidebar", "search-tests"], labels: ["main"]),
            SceneGraph.Commit(id: "search-tests", subject: String(localized: "Search tests"), parents: ["index"]),
            SceneGraph.Commit(id: "index", subject: String(localized: "Search index"), parents: ["sidebar"]),
            SceneGraph.Commit(
                id: "sidebar", subject: String(localized: "Fix the sidebar filter"), parents: ["release"]),
            SceneGraph.Commit(
                id: "release", subject: String(localized: "Release 0.9"), parents: ["older"], labels: ["v0.9"]),
        ]
    }

    /// The sample history clipped to `rect` and drawn at `scale` (1 is 100%), as the history's zoom draws it.
    static func sampleGraph(
        in rect: NSRect, scale: CGFloat = 1, rowHeight: CGFloat = SceneGraph.rowHeight,
        subjectsEnd: CGFloat? = nil, alpha: (Int) -> CGFloat = { _ in 1 }
    ) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        let context = NSGraphicsContext.current?.cgContext
        context?.translateBy(x: rect.minX, y: rect.minY)
        context?.scaleBy(x: scale, y: scale)
        let local = NSRect(x: 0, y: 0, width: rect.width / scale, height: rect.height / scale)
        SceneGraph.draw(
            SceneGraph.layout(
                sampleHistory, in: local, rowHeight: rowHeight,
                subjectsEnd: subjectsEnd.map { ($0 - rect.minX) / scale }),
            alpha: alpha)
        NSGraphicsContext.restoreGraphicsState()
    }
}
