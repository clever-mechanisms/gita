import AppKit

/// The centred repository + branch pill: one line, "name  ⑂ branch · ↑2", the name semibold and the branch secondary.
/// While a Git action runs the branch gives way to its status ("Pull…") behind a spinner, with a bar sweeping along the
/// pill's bottom edge; then the result ("Pull finished") shows for a moment in its colour.
@MainActor
final class RepositoryPill: NSControl {
    /// What the repository is doing, shown instead of the branch.
    struct Activity: Equatable {
        enum Kind: Equatable { case running, completed, paused, failed }
        var kind: Kind
        var text: String
    }

    private enum Metrics {
        static let horizontalInset: CGFloat = 14
        static let gap: CGFloat = 10 // name ↔ branch icon
        static let iconWidth: CGFloat = 15 // branch glyph + its gap
        static let chevronWidth: CGFloat = 14 // the pop-up chevron and its gap
        static let height: CGFloat = 30
        static let cornerRadius: CGFloat = 8
        /// Windows narrower than this get a narrower pill so the toolbar can keep it centred.
        static let narrowWindow: CGFloat = 1_200
        static let assumedWindowWidth: CGFloat = 1_440
        static let narrowWidths: ClosedRange<CGFloat> = 210...260
        static let wideWidths: ClosedRange<CGFloat> = 280...460
        /// The branch keeps up to this share of the room when both have to truncate.
        static let detailShare: CGFloat = 0.45
        static let menuGap: CGFloat = 4
    }

    private var name = ""
    private var branchDetail = ""
    private var hasBranch = false
    private(set) var activity: Activity?
    /// Turns the spinner and sweeps the bar while an action runs.
    private let ticker = FrameTicker()
    private var started = Date()
    /// What follows the name: the activity, else the branch.
    private var detail: String { activity?.text ?? branchDetail }
    private var pressed = false
    private var isDropTarget = false {
        didSet { if isDropTarget != oldValue { needsDisplay = true } }
    }
    var menuProvider: (() -> NSMenu?)?
    var canAcceptDrop: ((NSPasteboard) -> NSDragOperation)?
    var onAcceptDrop: ((NSPasteboard, NSView) -> Bool)?
    private var resizeObserver: NSObjectProtocol?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([GitaDragReference.pasteboardType])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("RepositoryPill is built in code") }

    private static var nameFont: NSFont { TextLines.system(14, weight: .semibold) }
    private static var detailFont: NSFont { TextLines.system(13) }
    private static func lineHeight(_ font: NSFont) -> CGFloat { ceil(font.ascender - font.descender) }
    private static let middle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        return style
    }()

    private var nameWidth: CGFloat { ceil(name.size(withAttributes: [.font: Self.nameFont]).width) }
    private var detailWidth: CGFloat {
        detail.isEmpty ? 0 : ceil(detail.size(withAttributes: [.font: Self.detailFont]).width)
    }
    /// The gap and branch glyph before the detail.
    private var detailLead: CGFloat {
        detail.isEmpty ? 0 : Metrics.gap + (hasBranch || activity != nil ? Metrics.iconWidth : 0)
    }

    override var intrinsicContentSize: NSSize {
        let width = nameWidth + detailLead + detailWidth + Metrics.chevronWidth
        let narrow = (window?.frame.width ?? Metrics.assumedWindowWidth) < Metrics.narrowWindow
        let range = narrow ? Metrics.narrowWidths : Metrics.wideWidths
        let fitted = ceil(width) + Metrics.horizontalInset * 2
        return NSSize(width: min(range.upperBound, max(range.lowerBound, fitted)), height: Metrics.height)
    }

    isolated deinit {
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        ticker.stop()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        resizeObserver = window.map { window in
            NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.invalidateIntrinsicContentSize() }
            }
        }
        invalidateIntrinsicContentSize()
        if window == nil { ticker.stop() } else { animate() }
    }

    func update(name: String, detail: String, hasBranch: Bool, activity: Activity? = nil) {
        guard
            name != self.name || detail != branchDetail || hasBranch != self.hasBranch || activity != self.activity
        else { return }
        if activity?.kind == .running && self.activity?.kind != .running { started = Date() }
        self.name = name
        branchDetail = detail
        self.hasBranch = hasBranch
        self.activity = activity
        animate()
        invalidateIntrinsicContentSize()
        needsDisplay = true
        let parts = [name, detail, activity?.text ?? ""].filter { !$0.isEmpty }
        setAccessibilityLabel(parts.joined(separator: ", "))
        toolTip = parts.joined(separator: "\n")
        if let activity, activity.kind != .running {
            NSAccessibility.post(
                element: self, notification: .announcementRequested,
                userInfo: [.announcement: activity.text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
    }

    /// The ticker runs only while an action runs in a window, and not with reduced motion.
    private func animate() {
        if activity?.kind == .running && window != nil && !Deck.reduceMotion {
            ticker.start { [weak self] in self?.needsDisplay = true }
        } else {
            ticker.stop()
        }
    }
    /// Seconds since the running action began, for the spinner and the bar.
    private var elapsed: CGFloat { CGFloat(Date().timeIntervalSince(started)) }

    /// How the room left of the chevron splits between the name and the branch.
    private func widths(available: CGFloat) -> (name: CGFloat, detail: CGFloat) {
        guard nameWidth + detailLead + detailWidth > available else { return (nameWidth, detailWidth) }
        let detailRoom = min(
            detailWidth, max((available - detailLead) * Metrics.detailShare, available - detailLead - nameWidth))
        return (max(0, available - detailLead - detailRoom), detailRoom)
    }

    /// Name and branch share one baseline, centred as a group; when the pill is too narrow the branch keeps up to
    /// 45% of the room and both truncate in the middle (the tooltip has the full text).
    override func draw(_: NSRect) {
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Metrics.cornerRadius, yRadius: Metrics.cornerRadius)
        (pressed ? Theme.control : Theme.window).setFill()
        path.fill()
        (isDropTarget ? Theme.accent : Theme.separator).setStroke()
        path.lineWidth = isDropTarget ? 2 : 1
        path.stroke()
        let alpha: CGFloat = isEnabled ? 1 : 0.5
        let inner = bounds.insetBy(dx: Metrics.horizontalInset, dy: 0)
        let available = inner.width - Metrics.chevronWidth
        let room = widths(available: available)
        var x = floor(inner.minX + (available - room.name - detailLead - room.detail) / 2)
        // One shared baseline: place both fonts so their baselines meet at the optical centre of the pill.
        let baseline = floor(bounds.midY + (Self.nameFont.capHeight / 2)).rounded()
        func rect(_ font: NSFont, _ width: CGFloat) -> NSRect {
            NSRect(x: x, y: baseline - font.ascender, width: width, height: Self.lineHeight(font) + 1)
        }
        name.draw(
            in: rect(Self.nameFont, room.name),
            withAttributes: [
                .font: Self.nameFont, .foregroundColor: Theme.text.withAlphaComponent(alpha),
                .paragraphStyle: Self.middle,
            ])
        x += room.name
        if !detail.isEmpty {
            x += Metrics.gap
            if let activity {
                drawActivityGlyph(activity.kind, at: x, baseline: baseline, alpha: alpha)
                x += Metrics.iconWidth
            } else if hasBranch {
                drawBranchGlyph(at: x, baseline: baseline, alpha: alpha)
                x += Metrics.iconWidth
            }
            let standing = hasBranch && activity == nil
            let color = activity.map { Self.color($0.kind) } ?? (standing ? Theme.checkedOut : Theme.secondaryText)
            detail.draw(
                in: rect(Self.detailFont, room.detail),
                withAttributes: [
                    .font: Self.detailFont, .foregroundColor: color.withAlphaComponent(alpha),
                    .paragraphStyle: Self.middle,
                ])
        }
        drawChevron(alpha: alpha)
        if activity?.kind == .running { drawProgressBar(in: path) }
    }

    private static func color(_ kind: Activity.Kind) -> NSColor {
        switch kind {
        case .running: Theme.accentText
        case .completed: Theme.success
        case .paused: Theme.needsInputText
        case .failed: Theme.failure
        }
    }

    /// A spinning arc while running; a filled mark for the result.
    private func drawActivityGlyph(_ kind: Activity.Kind, at x: CGFloat, baseline: CGFloat, alpha: CGFloat) {
        let size: CGFloat = 11
        let center = NSPoint(x: x + size / 2, y: baseline - Self.detailFont.capHeight / 2)
        let symbol: String
        switch kind {
        case .running:
            let arc = NSBezierPath()
            let start = -elapsed * 360
            arc.appendArc(
                withCenter: center, radius: size / 2 - 1, startAngle: start, endAngle: start + 270, clockwise: false)
            arc.lineWidth = 1.6
            arc.lineCapStyle = .round
            Theme.accentText.withAlphaComponent(alpha).setStroke()
            arc.stroke()
            return
        case .completed: symbol = "checkmark.circle.fill"
        case .paused: symbol = "pause.circle.fill"
        case .failed: symbol = "exclamationmark.triangle.fill"
        }
        guard let icon = Deck.symbol(symbol, size: size, color: Self.color(kind), inner: Theme.window) else { return }
        icon.draw(
            in: NSRect(
                x: x, y: (center.y - icon.size.height / 2).rounded(), width: icon.size.width,
                height: icon.size.height),
            from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
    }

    /// A short accent bar sweeping along the bottom edge, inside the pill's outline; still with reduced motion.
    private func drawProgressBar(in outline: NSBezierPath) {
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        let width = bounds.width * 0.3
        // One pass every 1.1 s, entering on the left and leaving on the right.
        let pass = (elapsed / 1.1).truncatingRemainder(dividingBy: 1)
        let x = Deck.reduceMotion ? (bounds.width - width) / 2 : pass * (bounds.width + width) - width
        let bar = NSRect(x: x, y: bounds.maxY - 2, width: width, height: 2)
        Theme.accent.setFill()
        NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawBranchGlyph(at x: CGFloat, baseline: CGFloat, alpha: CGFloat) {
        guard let icon = Deck.symbol("arrow.triangle.branch", size: 11, color: Theme.checkedOut) else { return }
        let iconY = baseline - Self.detailFont.capHeight / 2 - icon.size.height / 2
        icon.draw(
            in: NSRect(x: x, y: iconY.rounded(), width: icon.size.width, height: icon.size.height), from: .zero,
            operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
    }

    private func drawChevron(alpha: CGFloat) {
        guard let chevron = Deck.symbol("chevron.down", size: 9, color: Theme.tertiaryText) else { return }
        let x = bounds.maxX - Metrics.horizontalInset - chevron.size.width + 2
        chevron.draw(
            in: NSRect(
                x: x, y: (bounds.midY - chevron.size.height / 2).rounded(), width: chevron.size.width,
                height: chevron.size.height),
            from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func mouseDown(with _: NSEvent) {
        guard isEnabled, let menu = menuProvider?() else { return }
        pressed = true
        display()
        popUp(menu)
        pressed = false
        needsDisplay = true
    }

    private func popUp(_ menu: NSMenu) {
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + Metrics.menuGap), in: self)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .popUpButton }
    override func accessibilityPerformPress() -> Bool {
        if let menu = menuProvider?() { popUp(menu) }
        return true
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateDropOperation(sender.draggingPasteboard)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateDropOperation(sender.draggingPasteboard)
    }

    override func draggingExited(_: (any NSDraggingInfo)?) {
        isDropTarget = false
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        isDropTarget = false
        return onAcceptDrop?(sender.draggingPasteboard, self) ?? false
    }

    private func updateDropOperation(_ pasteboard: NSPasteboard) -> NSDragOperation {
        let operation = canAcceptDrop?(pasteboard) ?? []
        isDropTarget = !operation.isEmpty
        return operation
    }
}
