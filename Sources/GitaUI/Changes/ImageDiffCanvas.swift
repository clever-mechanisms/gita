import AppKit

/// Shared CoreGraphics drawing helpers for image diff surfaces (checkerboard, image blitting, crisp frame border).
@MainActor
enum ImageCanvasDrawing {
    private static let tileSize: CGFloat = 8

    static func drawCheckerboard(in rect: NSRect) {
        Theme.window.setFill()
        rect.fill()
        Theme.control.setFill()
        let cols = Int(ceil(rect.width / tileSize))
        let rows = Int(ceil(rect.height / tileSize))
        for row in 0..<rows {
            for col in 0..<cols where (row + col).isMultiple(of: 2) {
                let tile = NSRect(
                    x: rect.minX + CGFloat(col) * tileSize,
                    y: rect.minY + CGFloat(row) * tileSize,
                    width: min(tileSize, rect.maxX - (rect.minX + CGFloat(col) * tileSize)),
                    height: min(tileSize, rect.maxY - (rect.minY + CGFloat(row) * tileSize)))
                tile.fill()
            }
        }
    }

    static func drawImage(_ image: CGImage, in rect: NSRect, alpha: CGFloat = 1, sharp: Bool = false) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setAlpha(alpha)
        context.interpolationQuality = sharp ? .none : .high
        context.draw(image, in: rect)
        context.restoreGState()
    }

    static func drawBorder(in rect: NSRect, color: NSColor?) {
        let stroke = color ?? Theme.separator
        stroke.setStroke()
        let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1
        path.stroke()
    }

    static func drawPillBadge(_ text: String, at origin: NSPoint, fill: NSColor, textColor: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Theme.captionEmphasis,
            .foregroundColor: textColor,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let textSize = attributed.size()
        let pill = NSRect(
            x: origin.x, y: origin.y,
            width: ceil(textSize.width) + 12,
            height: ceil(textSize.height) + 4)
        fill.setFill()
        NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
        attributed.draw(at: NSPoint(x: pill.minX + 6, y: pill.minY + 2))
    }
}

/// Compact rounded status pill (`Added`, `Removed`, `Before`, `After`) for image diff headers.
@MainActor
final class ImageStatusPill: NSView {
    private let label = Deck.label("", font: Theme.captionEmphasis, color: Theme.text)
    private var fillColor: NSColor = Theme.control
    private var borderColor: NSColor = Theme.separator

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("ImageStatusPill is built in code") }

    func configure(title: String, tint: NSColor) {
        label.stringValue = title
        label.textColor = tint
        fillColor = tint.withAlphaComponent(0.14)
        borderColor = tint.withAlphaComponent(0.35)
        needsDisplay = true
    }

    override func draw(_: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        fillColor.setFill()
        path.fill()
        borderColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// Shared base for image preview surfaces: intrinsic sizing, pixel-sharp scaling, and double-click zoom toggle.
@MainActor
class ImageSurfaceBaseView: NSView {
    var sharpInterpolation = false { didSet { needsDisplay = true } }
    var displaySize = CGSize(width: 1, height: 1) {
        didSet {
            guard displaySize != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }
    var onDoubleClick: (() -> Void)?

    override var intrinsicContentSize: NSSize { displaySize }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        super.mouseDown(with: event)
    }
}

/// Single-image checkerboard frame with optional accent border.
@MainActor
final class ImageFrameSurfaceView: ImageSurfaceBaseView {
    var cgImage: CGImage? { didSet { needsDisplay = true } }
    var borderColor: NSColor? { didSet { needsDisplay = true } }

    override func draw(_: NSRect) {
        ImageCanvasDrawing.drawCheckerboard(in: bounds)
        if let cgImage {
            ImageCanvasDrawing.drawImage(cgImage, in: bounds, sharp: sharpInterpolation)
        }
        ImageCanvasDrawing.drawBorder(in: bounds, color: borderColor)
    }
}

/// Interactive curtain swipe view overlaying Before (left) and After (right) images.
@MainActor
final class ImageSwipeSurfaceView: ImageSurfaceBaseView {
    private static let handleDiameter: CGFloat = 24
    private static let badgeMinimumWidth: CGFloat = 150

    var oldImage: CGImage? { didSet { needsDisplay = true } }
    var newImage: CGImage? { didSet { needsDisplay = true } }
    var splitFraction: CGFloat = 0.5 {
        didSet {
            let clamped = min(1, max(0, splitFraction))
            if clamped != splitFraction { splitFraction = clamped }
            needsDisplay = true
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func draw(_: NSRect) {
        ImageCanvasDrawing.drawCheckerboard(in: bounds)
        let splitX = (bounds.width * splitFraction).rounded()
        drawClipped(oldImage, clipRect: NSRect(x: 0, y: 0, width: splitX, height: bounds.height))
        drawClipped(newImage, clipRect: NSRect(x: splitX, y: 0, width: bounds.width - splitX, height: bounds.height))
        ImageCanvasDrawing.drawBorder(in: bounds, color: nil)
        drawDivider(at: splitX)
        drawCornerLabels()
    }

    private func drawClipped(_ image: CGImage?, clipRect: NSRect) {
        guard let image, clipRect.width > 0, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.clip(to: clipRect)
        ImageCanvasDrawing.drawImage(image, in: bounds, sharp: sharpInterpolation)
        context.restoreGState()
    }

    private func drawDivider(at splitX: CGFloat) {
        let lineX = min(max(splitX, 1), max(1, bounds.width - 1))
        Theme.accent.setFill()
        NSRect(x: lineX - 1, y: 0, width: 2, height: bounds.height).fill()
        let diameter = Self.handleDiameter
        let handleRect = NSRect(
            x: lineX - diameter / 2,
            y: bounds.midY - diameter / 2,
            width: diameter,
            height: diameter)
        let circle = NSBezierPath(ovalIn: handleRect)
        Theme.window.setFill()
        circle.fill()
        Theme.accent.setStroke()
        circle.lineWidth = 1.5
        circle.stroke()
        if let symbol = Deck.symbol("chevron.left.chevron.right", size: 10, weight: .semibold, color: Theme.text) {
            let size = symbol.size
            symbol.draw(
                in: NSRect(
                    x: handleRect.midX - size.width / 2,
                    y: handleRect.midY - size.height / 2,
                    width: size.width,
                    height: size.height),
                from: .zero, operation: .sourceOver, fraction: 1)
        }
    }

    private func drawCornerLabels() {
        guard bounds.width >= Self.badgeMinimumWidth, bounds.height >= 48 else { return }
        let topY = bounds.height - 26
        let badgeBackground = Theme.window.withAlphaComponent(0.86)
        ImageCanvasDrawing.drawPillBadge(
            String(localized: "Before"), at: NSPoint(x: 8, y: topY), fill: badgeBackground, textColor: Theme.failure)
        let afterTitle = String(localized: "After")
        let width = ceil(
            NSAttributedString(string: afterTitle, attributes: [.font: Theme.captionEmphasis]).size().width)
        ImageCanvasDrawing.drawPillBadge(
            afterTitle, at: NSPoint(x: bounds.width - width - 20, y: topY),
            fill: badgeBackground, textColor: Theme.success)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        window?.makeFirstResponder(self)
        updateSplit(for: event)
    }

    override func mouseDragged(with event: NSEvent) {
        updateSplit(for: event)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: splitFraction -= 0.05
        case 124: splitFraction += 0.05
        default: super.keyDown(with: event)
        }
    }

    private func updateSplit(for event: NSEvent) {
        guard bounds.width > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        splitFraction = point.x / bounds.width
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func accessibilityValue() -> Any? { Int((splitFraction * 100).rounded()) }
}

/// Onion-skin blend surface drawing After over Before at variable opacity.
@MainActor
final class ImageOnionSurfaceView: ImageSurfaceBaseView {
    var oldImage: CGImage? { didSet { needsDisplay = true } }
    var newImage: CGImage? { didSet { needsDisplay = true } }
    var opacity: CGFloat = 0.5 { didSet { needsDisplay = true } }

    override func draw(_: NSRect) {
        ImageCanvasDrawing.drawCheckerboard(in: bounds)
        if let oldImage {
            ImageCanvasDrawing.drawImage(oldImage, in: bounds, alpha: 1, sharp: sharpInterpolation)
        }
        if let newImage {
            ImageCanvasDrawing.drawImage(newImage, in: bounds, alpha: opacity, sharp: sharpInterpolation)
        }
        ImageCanvasDrawing.drawBorder(in: bounds, color: nil)
    }
}

/// One labelled card (`Before` or `After`) in Side-by-Side image comparison.
@MainActor
final class ImageSideCardView: NSView {
    let pill = ImageStatusPill()
    let captionLabel = Deck.caption("")
    let surface = ImageFrameSurfaceView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let header = Deck.hstack([pill, captionLabel], spacing: 6)
        let stack = Deck.vstack([header, surface], spacing: 8)
        stack.alignment = .centerX
        Deck.pin(stack, in: self)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("ImageSideCardView is built in code") }

    func configure(
        title: String, tint: NSColor, caption: String, image: CGImage, displaySize: CGSize, sharp: Bool
    ) {
        pill.configure(title: title, tint: tint)
        captionLabel.stringValue = caption
        surface.cgImage = image
        surface.borderColor = tint.withAlphaComponent(0.45)
        surface.sharpInterpolation = sharp
        surface.displaySize = displaySize
    }
}
