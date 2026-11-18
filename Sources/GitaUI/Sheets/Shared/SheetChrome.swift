import AppKit

/// The window of a fixed-layout review sheet: a column of rows with fixed heights, a status row with a spinner, and a
/// footer of buttons. The window fits its shown rows and stays inside the parent window and the screen; one row can
/// be flexible and shrink first when the content does not fit.
@MainActor
final class SheetChrome {
    struct Layout {
        var width: CGFloat
        var spacing: CGFloat = 10
        var minimumHeight: CGFloat = 150
    }
    private enum Metrics {
        static let horizontalInset: CGFloat = 20
        static let topInset: CGFloat = 18
        static let footerGap: CGFloat = 16
        static let footerHeight: CGFloat = 30
        static let bottomInset: CGFloat = 16
        static let statusMinimumHeight: CGFloat = 16
        static let statusMaximumHeight: CGFloat = 44
        static let statusMeasureHeight: CGFloat = 50
        static let spinnerSide: CGFloat = 16
        static let spinnerRoom: CGFloat = 24
        static let initialHeight: CGFloat = 180
        static let fallbackScreen = NSRect(x: 0, y: 0, width: 1_200, height: 800)
        static let screenMargin = NSSize(width: 40, height: 50)
        static let parentMargin: CGFloat = 24
    }
    private struct FlexibleRow {
        let view: NSView
        let preferred: CGFloat
        let minimum: CGFloat
    }

    let window: NSWindow
    let column = NSStackView()
    let footer = NSStackView()
    let status = Style.label("", size: 11)
    private let statusRow = NSStackView()
    private let progress = NSProgressIndicator()
    private let layout: Layout
    private var heights: [ObjectIdentifier: NSLayoutConstraint] = [:]
    private var flexibleRow: FlexibleRow?

    init(title: String, layout: Layout, identifier: String, styleMask: NSWindow.StyleMask = [.titled, .closable]) {
        self.layout = layout
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: layout.width, height: Metrics.initialHeight), styleMask: styleMask,
            backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        let root = ThemedBackgroundView()
        window.contentView = root
        configureStacks(in: root)
        configureStatus(identifier: identifier)
        window.center()
    }

    /// The content width: the preferred width, narrowed to fit the parent window and screen.
    var width: CGFloat { min(layout.width, maximumSize.width) }

    /// The largest content size: inside the parent window (once attached) and the screen's visible frame.
    var maximumSize: NSSize {
        let parent = window.sheetParent
        let visible = (parent?.screen ?? window.screen ?? NSScreen.main)?.visibleFrame
        return Self.maximumSize(visible: visible, parentContent: parent?.contentLayoutRect.size)
    }

    static func maximumSize(visible: NSRect?, parentContent: NSSize?) -> NSSize {
        let screen = (visible ?? Metrics.fallbackScreen).size
        let parent = parentContent ?? screen
        return NSSize(
            width: min(screen.width - Metrics.screenMargin.width, parent.width - Metrics.parentMargin),
            height: min(screen.height - Metrics.screenMargin.height, parent.height - Metrics.parentMargin))
    }

    /// Moves `frame` inside `visible` where it can.
    static func clamp(_ frame: NSRect, to visible: NSRect?) -> NSRect {
        guard let visible else { return frame }
        var frame = frame
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        return frame
    }

    @discardableResult func add(_ view: NSView, height: CGFloat) -> NSView {
        column.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        let constraint = view.heightAnchor.constraint(equalToConstant: height)
        constraint.isActive = true
        heights[ObjectIdentifier(view)] = constraint
        return view
    }
    func complete(footer controls: [NSView]) {
        add(statusRow, height: Metrics.statusMinimumHeight)
        for control in controls { footer.addArrangedSubview(control) }
        fit()
    }
    func setHeight(_ height: CGFloat, for view: NSView) { heights[ObjectIdentifier(view)]?.constant = height }
    func setFlexibleRow(_ view: NSView, preferred: CGFloat, minimum: CGFloat) {
        flexibleRow = FlexibleRow(view: view, preferred: preferred, minimum: minimum)
    }
    func show(_ value: SheetStatus) {
        status.stringValue = value.message
        status.toolTip = value.message
        status.textColor = value.isError ? .systemRed : .labelColor
        statusRow.isHidden = value.message.isEmpty
        progress.isHidden = !value.isBusy
        if value.isBusy { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        let room = width - 2 * Metrics.horizontalInset - (value.isBusy ? Metrics.spinnerRoom : 0)
        let measured = NSAttributedString(
            string: value.message, attributes: [.font: status.font ?? TextLines.system(11)]
        ).boundingRect(
            with: NSSize(width: room, height: Metrics.statusMeasureHeight), options: .usesLineFragmentOrigin
        ).height
        setHeight(
            max(Metrics.statusMinimumHeight, min(Metrics.statusMaximumHeight, ceil(measured))), for: statusRow)
        fit()
    }

    /// Sizes the window to its shown rows, shrinking the flexible row first, and keeps it on screen.
    func fit() {
        let maximumHeight = maximumSize.height
        if let flexibleRow { setHeight(flexibleRow.preferred, for: flexibleRow.view) }
        let shown = column.arrangedSubviews.filter { !$0.isHidden }
        let rows = shown.reduce(CGFloat(0)) { $0 + (heights[ObjectIdentifier($1)]?.constant ?? 0) }
        var height =
            Metrics.topInset + rows + CGFloat(max(0, shown.count - 1)) * layout.spacing + Metrics.footerGap
            + Metrics.footerHeight + Metrics.bottomInset
        if height > maximumHeight, let flexibleRow, !flexibleRow.view.isHidden {
            let reduced = max(flexibleRow.minimum, flexibleRow.preferred - (height - maximumHeight))
            setHeight(reduced, for: flexibleRow.view)
            height -= flexibleRow.preferred - reduced
        }
        let size = NSSize(width: width, height: min(maximumHeight, max(layout.minimumHeight, height)))
        guard window.contentView?.frame.size != size else { return }
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.midX - frame.width / 2, y: window.frame.maxY - frame.height)
        frame = Self.clamp(frame, to: window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame)
        window.setFrame(frame, display: true, animate: false)
    }

    static func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }
    /// A footer-sized button; its controller binds the action once it exists.
    static func button(_ title: String, id: String, symbol: String? = nil) -> NSButton {
        let button = Style.button(title, symbol: symbol, target: nil, action: nil)
        button.controlSize = .regular
        button.font = TextLines.system(13)
        button.setAccessibilityIdentifier(id)
        return button
    }
    static func wrappingLabel(_ text: String = "", lines: Int = 2) -> NSTextField {
        let label = Style.label(text)
        label.maximumNumberOfLines = lines
        label.lineBreakMode = .byWordWrapping
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
    /// A plain-text editor in a bordered scroll view, with typography substitutions off (messages are Git text).
    static func plainTextEditor(_ editor: NSTextView, size: CGFloat, label: String, id: String) -> NSScrollView {
        editor.isRichText = false
        editor.allowsUndo = true
        editor.font = TextLines.system(size)
        editor.textColor = .textColor
        editor.backgroundColor = .textBackgroundColor
        editor.textContainerInset = NSSize(width: 7, height: 7)
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.setAccessibilityLabel(label)
        editor.setAccessibilityIdentifier(id)
        let scroll = Style.scroll(editor)
        scroll.borderType = .bezelBorder
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        return scroll
    }

    private func configureStacks(in root: NSView) {
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = layout.spacing
        column.detachesHiddenViews = true
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.detachesHiddenViews = true
        for view in [column, footer] {
            root.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Metrics.horizontalInset),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Metrics.horizontalInset),
            column.topAnchor.constraint(equalTo: root.topAnchor, constant: Metrics.topInset),
            footer.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            footer.topAnchor.constraint(greaterThanOrEqualTo: column.bottomAnchor, constant: Metrics.footerGap),
            footer.heightAnchor.constraint(equalToConstant: Metrics.footerHeight),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Metrics.bottomInset),
        ])
    }
    private func configureStatus(identifier: String) {
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.widthAnchor.constraint(equalToConstant: Metrics.spinnerSide).isActive = true
        progress.heightAnchor.constraint(equalToConstant: Metrics.spinnerSide).isActive = true
        status.maximumNumberOfLines = 3
        status.lineBreakMode = .byWordWrapping
        status.cell?.wraps = true
        status.cell?.isScrollable = false
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.setAccessibilityIdentifier(identifier + ".status")
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 8
        statusRow.detachesHiddenViews = true
        statusRow.addArrangedSubview(progress)
        statusRow.addArrangedSubview(status)
        statusRow.isHidden = true
    }
}
