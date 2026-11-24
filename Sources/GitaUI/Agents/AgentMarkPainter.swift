import AppKit
import os

/// Small vector marks that identify each coding agent where its name used to be written out ("Claude Code").
/// The official logos (LobeHub Icons, MIT, in `Resources/AgentMarks` with the licence; the same marks Orca shows):
/// Claude's terracotta spark in its own colour, Gemini's sparkle filled with its blue-violet-rose gradient,
/// Antigravity's arch in Google's blue, green, yellow and red, and the
/// monochrome ones (OpenAI's knot for Codex, Cursor's cube, opencode) in the text colour so they read on every theme.
/// Aider has no official mark there and keeps a drawn tile; any mark whose file is missing falls back to a drawing.
enum AgentMarkPainter {
    enum Kind: CaseIterable { case claude, openAI, gemini, antigravity, cursor, opencode, aider }

    /// Draws `kind` into `rect` (a square) of `context`, whose y axis points up. `ink` is the monochrome colour;
    /// `logos` are the official marks (a kind without one is drawn).
    static func draw(
        _ kind: Kind, in rect: CGRect, context: CGContext, ink: CGColor, logos: [Kind: NSImage] = Self.logos
    ) {
        let side = min(rect.width, rect.height)
        let box = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        if let logo = logos[kind] {
            drawLogo(logo, kind: kind, in: box, context: context, ink: ink)
            return
        }
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: box.minX, y: box.minY)
        context.scaleBy(x: side, y: side) // unit square from here on
        switch kind {
        case .claude: claude(context)
        case .openAI: openAI(context, ink: ink, side: side)
        case .gemini: gemini(context)
        case .antigravity: antigravity(context)
        case .cursor: cursor(context, ink: ink)
        case .opencode: opencode(context, ink: ink)
        case .aider: aider(context)
        }
    }

    /// Official logo files per mark; `.aider` has none.
    private static let files: [Kind: String] = [
        .claude: "claude-color", .openAI: "openai", .gemini: "gemini", .antigravity: "antigravity", .cursor: "cursor",
        .opencode: "opencode",
    ]
    /// Loaded once per resource folder; NSImage renders the SVG as vectors (CoreSVG) at whatever size it is drawn.
    private static let logoCache = OSAllocatedUnfairLock<(root: URL?, logos: [Kind: NSImage])?>(initialState: nil)
    static var logos: [Kind: NSImage] {
        let root = BundledResources.root
        return logoCache.withLock { cache in
            if let cache, cache.root == root { return cache.logos }
            let logos = loadLogos(from: root?.appendingPathComponent("AgentMarks", isDirectory: true))
            cache = (root, logos)
            return logos
        }
    }
    static func loadLogos(from directory: URL?) -> [Kind: NSImage] {
        guard let directory else { return [:] }
        var logos: [Kind: NSImage] = [:]
        for (kind, name) in files {
            if let image = NSImage(contentsOf: directory.appendingPathComponent(name + ".svg")), image.isValid {
                logos[kind] = image
            }
        }
        return logos
    }
    private static func drawLogo(_ logo: NSImage, kind: Kind, in box: CGRect, context: CGContext, ink: CGColor) {
        context.saveGState()
        defer { context.restoreGState() }
        // Monochrome files are black (`currentColor`): drawn into a layer, then recoloured through their own alpha.
        let recolour = kind != .claude
        if recolour { context.beginTransparencyLayer(in: box, auxiliaryInfo: nil) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        logo.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard recolour else { return }
        context.setBlendMode(.sourceIn)
        switch kind {
        case .gemini: fillGemini(context, box: box)
        case .antigravity: fillAntigravity(context, box: box)
        default:
            context.setFillColor(ink)
            context.fill(box)
        }
        context.endTransparencyLayer()
    }

    static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(
            srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }

    /// Claude: a terracotta spark of tapered rays of uneven length.
    private static func claude(_ c: CGContext) {
        let lengths: [CGFloat] = [0.50, 0.40, 0.47, 0.38, 0.50, 0.42, 0.46, 0.39, 0.49, 0.41, 0.45, 0.38]
        c.setFillColor(rgb(0xD97757))
        for (index, length) in lengths.enumerated() {
            let angle = CGFloat(index) * .pi / 6 + 0.12
            let direction = CGPoint(x: cos(angle), y: sin(angle))
            let normal = CGPoint(x: -direction.y, y: direction.x)
            let base: CGFloat = 0.075
            let tip: CGFloat = 0.036
            let start = CGPoint(x: 0.5 + direction.x * 0.04, y: 0.5 + direction.y * 0.04)
            let end = CGPoint(x: 0.5 + direction.x * (length - tip), y: 0.5 + direction.y * (length - tip))
            c.move(to: CGPoint(x: start.x + normal.x * base, y: start.y + normal.y * base))
            c.addLine(to: CGPoint(x: end.x + normal.x * tip, y: end.y + normal.y * tip))
            c.addLine(to: CGPoint(x: end.x - normal.x * tip, y: end.y - normal.y * tip))
            c.addLine(to: CGPoint(x: start.x - normal.x * base, y: start.y - normal.y * base))
            c.closePath()
            c.fillPath()
            c.fillEllipse(in: CGRect(x: end.x - tip, y: end.y - tip, width: tip * 2, height: tip * 2))
        }
        c.fillEllipse(in: CGRect(x: 0.5 - 0.1, y: 0.5 - 0.1, width: 0.2, height: 0.2))
    }

    /// OpenAI (Codex): six rounded links turned 60° apart around the centre, stroked in the text colour.
    private static func openAI(_ c: CGContext, ink: CGColor, side: CGFloat) {
        c.setStrokeColor(ink)
        c.setLineWidth(max(0.068, 1.1 / side))
        c.setLineJoin(.round)
        for index in 0..<6 {
            c.saveGState()
            c.translateBy(x: 0.5, y: 0.5)
            c.rotate(by: CGFloat(index) * .pi / 3)
            // One link: a stadium standing beside the centre, leaning into the next one.
            let link = CGRect(x: 0.05, y: -0.05, width: 0.22, height: 0.42)
            c.addPath(CGPath(roundedRect: link, cornerWidth: 0.11, cornerHeight: 0.11, transform: nil))
            c.strokePath()
            c.restoreGState()
        }
    }

    /// Gemini: a four-pointed sparkle with curved sides, blue to violet to rose.
    private static func gemini(_ c: CGContext) {
        let path = CGMutablePath()
        let pinch: CGFloat = 0.08
        path.move(to: CGPoint(x: 0.5, y: 1))
        path.addCurve(
            to: CGPoint(x: 1, y: 0.5), control1: CGPoint(x: 0.5 + pinch, y: 0.5 + pinch * 2.2),
            control2: CGPoint(x: 0.5 + pinch * 2.2, y: 0.5 + pinch))
        path.addCurve(
            to: CGPoint(x: 0.5, y: 0), control1: CGPoint(x: 0.5 + pinch * 2.2, y: 0.5 - pinch),
            control2: CGPoint(x: 0.5 + pinch, y: 0.5 - pinch * 2.2))
        path.addCurve(
            to: CGPoint(x: 0, y: 0.5), control1: CGPoint(x: 0.5 - pinch, y: 0.5 - pinch * 2.2),
            control2: CGPoint(x: 0.5 - pinch * 2.2, y: 0.5 - pinch))
        path.addCurve(
            to: CGPoint(x: 0.5, y: 1), control1: CGPoint(x: 0.5 - pinch * 2.2, y: 0.5 + pinch),
            control2: CGPoint(x: 0.5 - pinch, y: 0.5 + pinch * 2.2))
        path.closeSubpath()
        c.addPath(path)
        c.clip()
        fillGemini(c, box: CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// Gemini's blue to violet to rose, corner to corner across `box`.
    private static func fillGemini(_ c: CGContext, box: CGRect) {
        guard
            let gradient = CGGradient(
                colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                colors: [rgb(0x3C7BF5), rgb(0x8E6FD8), rgb(0xD9677A)] as CFArray, locations: [0, 0.6, 1])
        else { return }
        c.drawLinearGradient(
            gradient, start: CGPoint(x: box.minX + box.width * 0.1, y: box.minY + box.height * 0.1),
            end: CGPoint(x: box.minX + box.width * 0.95, y: box.minY + box.height * 0.95), options: [])
    }

    /// Antigravity: an arch on two flared feet, the logo's own outline (its 24-point box, y pointing down).
    private static func antigravity(_ c: CGContext) {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x / 24, y: 1 - y / 24) }
        let path = CGMutablePath()
        path.move(to: point(21.751, 22.607))
        path.addCurve(to: point(23.259, 21.099), control1: point(23.091, 23.612), control2: point(25.101, 22.942))
        path.addCurve(to: point(12.037, 1), control1: point(17.73, 15.74), control2: point(18.904, 1))
        path.addCurve(to: point(0.815, 21.1), control1: point(5.17, 1), control2: point(6.342, 15.74))
        path.addCurve(to: point(2.322, 22.606), control1: point(-1.195, 23.109), control2: point(0.982, 23.611))
        path.addCurve(to: point(12.037, 12.892), control1: point(7.514, 19.089), control2: point(7.179, 12.892))
        path.addCurve(to: point(21.751, 22.607), control1: point(16.894, 12.892), control2: point(16.559, 19.089))
        path.closeSubpath()
        c.beginTransparencyLayer(auxiliaryInfo: nil)
        c.addPath(path)
        c.clip()
        fillAntigravity(c, box: CGRect(x: 0, y: 0, width: 1, height: 1))
        c.endTransparencyLayer()
    }

    /// Antigravity's colours as its logo blends them: blue below, green on the left foot, yellow over the top, red on
    /// the right. Paints only where something is already drawn (the logo in its layer, or the clipped outline).
    private static func fillAntigravity(_ c: CGContext, box: CGRect) {
        c.setFillColor(rgb(0x3186FF))
        c.fill(box)
        c.setBlendMode(.sourceAtop)
        let space = CGColorSpace(name: CGColorSpace.sRGB)
        let blobs: [(UInt32, CGPoint, CGFloat)] = [
            (0x00B95C, CGPoint(x: -0.05, y: 0.6), 0.55), (0xFFE432, CGPoint(x: 0.3, y: 1.05), 0.5),
            (0xFC413D, CGPoint(x: 1, y: 0.8), 0.5),
        ]
        for (hex, centre, radius) in blobs {
            guard
                let gradient = CGGradient(
                    colorsSpace: space, colors: [rgb(hex), rgb(hex, 0)] as CFArray, locations: nil)
            else { continue }
            let at = CGPoint(x: box.minX + box.width * centre.x, y: box.minY + box.height * centre.y)
            c.drawRadialGradient(
                gradient, startCenter: at, startRadius: 0, endCenter: at, endRadius: box.width * radius, options: [])
        }
    }

    /// Cursor: an isometric cube, three faces in three tints of the text colour.
    private static func cursor(_ c: CGContext, ink: CGColor) {
        let r: CGFloat = 0.48
        func corner(_ degrees: CGFloat) -> CGPoint {
            CGPoint(x: 0.5 + r * cos(degrees * .pi / 180), y: 0.5 + r * sin(degrees * .pi / 180))
        }
        let top = corner(90)
        let upperRight = corner(30)
        let lowerRight = corner(-30)
        let bottom = corner(-90)
        let lowerLeft = corner(210)
        let upperLeft = corner(150)
        let center = CGPoint(x: 0.5, y: 0.5)
        let faces: [([CGPoint], CGFloat)] = [
            ([top, upperRight, center, upperLeft], 0.55), ([upperLeft, center, bottom, lowerLeft], 1),
            ([center, upperRight, lowerRight, bottom], 0.78),
        ]
        for (points, alpha) in faces {
            c.addLines(between: points)
            c.closePath()
            c.setFillColor(ink.copy(alpha: ink.alpha * alpha) ?? ink)
            c.fillPath()
        }
    }

    /// OpenCode: a heavy square ring.
    private static func opencode(_ c: CGContext, ink: CGColor) {
        c.setFillColor(ink)
        c.addPath(
            CGPath(
                roundedRect: CGRect(x: 0.08, y: 0.08, width: 0.84, height: 0.84), cornerWidth: 0.12, cornerHeight: 0.12,
                transform: nil))
        c.addRect(CGRect(x: 0.32, y: 0.32, width: 0.36, height: 0.36))
        c.fillPath(using: .evenOdd)
    }

    /// Aider: a green tile with a white "a".
    private static func aider(_ c: CGContext) {
        c.setFillColor(rgb(0x14A44D))
        c.addPath(
            CGPath(
                roundedRect: CGRect(x: 0.04, y: 0.04, width: 0.92, height: 0.92), cornerWidth: 0.24, cornerHeight: 0.24,
                transform: nil))
        c.fillPath()
        c.setStrokeColor(.white)
        c.setLineWidth(0.12)
        c.setLineCap(.round)
        c.addEllipse(in: CGRect(x: 0.26, y: 0.24, width: 0.4, height: 0.4))
        c.strokePath()
        c.move(to: CGPoint(x: 0.68, y: 0.7))
        c.addLine(to: CGPoint(x: 0.68, y: 0.26))
        c.strokePath()
    }
}
