import AppKit
import GitaCore

@MainActor
final class VelocitySparklineOverlayView: NSView {
    let presenter = VelocitySparklinePresenter()
    var onSelectBucket: ((VelocityBucket) -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 240, height: 64) }
    private static let homeKey: UInt16 = 115
    private static let endKey: UInt16 = 119
    private let spinner = NSProgressIndicator()
    private var spinnerDelay: Task<Void, Never>?
    private var plot: CGRect { bounds.insetBy(dx: 4, dy: 8) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.usesThreadedAnimation = false
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        presenter.onChange = { [weak self] in self?.refresh() }
        focusRingType = .default
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        smartDiffAccessibility(String(localized: "Commit velocity"), "sparkline.view")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("Use init(frame:)") }

    func update(_ buckets: [VelocityBucket]) {
        presenter.update(buckets)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.inset.setFill()
        dirtyRect.fill()
        guard case .loaded(let buckets, let hover, let selected) = presenter.state,
            plot.width > 0, plot.height > 0
        else {
            guard case .empty = presenter.state else { return }
            let message = String(localized: "No commit activity")
            let text = NSAttributedString(
                string: message,
                attributes: [
                    .font: Theme.caption,
                    .foregroundColor: Theme.secondaryText,
                ])
            text.draw(
                at: CGPoint(
                    x: max(0, bounds.midX - text.size().width / 2),
                    y: bounds.midY - text.size().height / 2))
            return
        }
        let width = plot.width / CGFloat(buckets.count)
        let points = buckets.enumerated().map { index, bucket in
            CGPoint(
                x: plot.minX + (CGFloat(index) + 0.5) * width,
                y: plot.maxY - CGFloat(bucket.normalizedVelocity) * plot.height)
        }
        drawCurve(points)
        for (index, bucket) in buckets.enumerated() {
            let height = CGFloat(bucket.normalizedChurn) * plot.height / 3
            Theme.working.withAlphaComponent(0.32).setFill()
            CGRect(x: points[index].x - width / 4, y: plot.maxY - height, width: width / 2, height: height).fill()
            if bucket.milestoneCount > 0 { dot(at: points[index], radius: 2, color: Theme.needsInputText) }
        }
        if let index = hover ?? selected { drawSelection(at: points[index]) }
    }

    private func drawCurve(_ points: [CGPoint]) {
        guard let first = points.first, let last = points.last else { return }
        let curve = NSBezierPath()
        curve.move(to: CGPoint(x: plot.minX, y: first.y))
        for point in points { curve.line(to: point) }
        curve.line(to: CGPoint(x: plot.maxX, y: last.y))
        Theme.accent.setStroke()
        curve.lineWidth = 1.5
        curve.lineJoinStyle = .round
        curve.stroke()
        curve.line(to: CGPoint(x: plot.maxX, y: plot.maxY))
        curve.line(to: CGPoint(x: plot.minX, y: plot.maxY))
        curve.close()
        Theme.accent.withAlphaComponent(0.14).setFill()
        curve.fill()
    }

    private func dot(at point: CGPoint, radius: CGFloat, color: NSColor) {
        color.setFill()
        NSBezierPath(
            ovalIn: CGRect(
                x: point.x - radius, y: point.y - radius,
                width: radius * 2, height: radius * 2)
        ).fill()
    }

    private func drawSelection(at point: CGPoint) {
        Theme.separator.setFill()
        CGRect(x: point.x, y: 0, width: 1, height: bounds.height).fill()
        dot(at: point, radius: 3, color: Theme.accentText)
        let text = NSAttributedString(
            string: toolTip ?? "",
            attributes: [
                .font: Theme.caption, .foregroundColor: Theme.text, .paragraphStyle: Deck.truncatingTail,
            ])
        let width = min(bounds.width, ceil(text.size().width) + 16)
        let pill = CGRect(
            x: max(0, min(bounds.width - width, point.x - width / 2)), y: 0,
            width: width, height: min(20, bounds.height))
        Deck.quietFill.setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        text.draw(in: pill.insetBy(dx: 8, dy: max(0, (pill.height - text.size().height) / 2)))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        replaceHoverTrackingArea()
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                owner: self))
    }

    private func position(_ event: NSEvent) -> CGFloat {
        (convert(event.locationInWindow, from: nil).x - plot.minX) / max(1, plot.width)
    }

    override func mouseMoved(with event: NSEvent) {
        let x = position(event)
        guard case .loaded(_, let hover, _) = presenter.state, presenter.index(at: x) != hover else { return }
        presenter.hover(at: x)
    }
    override func mouseExited(with _: NSEvent) {
        presenter.hover(at: nil)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if let index = presenter.index(at: position(event)) {
            presenter.select(index: index)
            activate()
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case KeyPress.leftArrow: presenter.step(-1)
        case KeyPress.rightArrow: presenter.step(1)
        case Self.homeKey: presenter.select(index: 0)
        case Self.endKey: presenter.select(index: .max)
        case KeyPress.escape where presenter.activeBucket != nil: presenter.clearSelection()
        default:
            if KeyPress.isActivation(event) || event.keyCode == KeyPress.keypadEnter {
                activate()
            } else {
                super.keyDown(with: event)
            }
        }
    }

    @discardableResult
    private func activate() -> Bool {
        guard let bucket = presenter.activeBucket else { return false }
        onSelectBucket?(bucket)
        return true
    }

    override func accessibilityPerformIncrement() -> Bool {
        presenter.step(1)
        return presenter.activeBucket != nil
    }
    override func accessibilityPerformDecrement() -> Bool {
        presenter.step(-1)
        return presenter.activeBucket != nil
    }
    override func accessibilityPerformPress() -> Bool { activate() }

    private func refresh() {
        toolTip = presenter.activeBucket.map(presenter.tooltip)
        setAccessibilityValue(toolTip ?? String(localized: "Commit activity"))
        needsDisplay = true
        if case .loading = presenter.state {
            guard spinnerDelay == nil else { return }
            spinnerDelay = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                self?.spinner.isHidden = false
                self?.spinner.startAnimation(nil)
            }
        } else if spinnerDelay != nil {
            spinnerDelay?.cancel()
            spinnerDelay = nil
            spinner.stopAnimation(nil)
            spinner.isHidden = true
        }
    }

    deinit { spinnerDelay?.cancel() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func drawFocusRingMask() { bounds.fill() }
    override var focusRingMaskBounds: NSRect { bounds }
}
