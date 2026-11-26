import AppKit

@MainActor
final class WorkflowTableView: NSTableView {
    var onSpaceKey: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " ", let onSpaceKey {
            onSpaceKey()
            return
        }
        super.keyDown(with: event)
    }
}

/// Common layout for the two repository utilities. The controllers own their selections, commands and tasks.
@MainActor
final class WorkflowWindowContent {
    let window: NSWindow
    let table = WorkflowTableView()
    let header = NSStackView()
    let controls = NSStackView()
    let subtitle = Style.label("", color: Theme.secondaryText)
    let summary = Style.label("", weight: .medium)
    let status = Style.label("", size: 11, color: Theme.secondaryText)
    let empty = SheetChrome.wrappingLabel(lines: 4)
    let refresh = SheetChrome.button(String(localized: "Refresh"), id: "workflow.refresh", symbol: "arrow.clockwise")
    let action: NSButton
    private let column = NSTableColumn(identifier: .init("workflow.row"))

    init(title: String, actionTitle: String) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 490),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = title
        window.minSize = NSSize(width: 680, height: 340)
        window.isReleasedWhenClosed = false
        action = SheetChrome.button(actionTitle, id: "workflow.action")
        action.bezelColor = Theme.accent
        summary.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        header.addArrangedSubview(
            Style.stack(
                [Style.label(title, size: 19, weight: .semibold), subtitle],
                vertical: true, spacing: 3))
        header.addArrangedSubview(SheetChrome.spacer())
        header.addArrangedSubview(refresh)
        table.headerView = nil
        table.backgroundColor = Theme.window
        table.rowHeight = 40
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.setAccessibilityLabel(title)
        let root = ThemedBackgroundView()
        let body = NSView()
        Style.fill(Style.scroll(table), in: body)
        body.addSubview(empty)
        empty.alignment = .center
        empty.textColor = Theme.secondaryText
        empty.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            empty.centerXAnchor.constraint(equalTo: body.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: body.centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: body.widthAnchor, constant: -32),
        ])
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = Style.stack([
            Style.stack([summary, status], vertical: true, spacing: 3),
            SheetChrome.spacer(), action,
        ])
        let stack = Style.stack([header, controls, body, footer], vertical: true, spacing: 12)
        Style.fill(stack, in: root, inset: 16)
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        window.contentView = root
        window.center()
    }

    func feedback(_ text: String, emptyMessage: String, isError: Bool = false) {
        status.stringValue = text
        status.toolTip = text
        status.textColor = isError ? Theme.failure : Theme.secondaryText
        empty.stringValue = emptyMessage
        empty.isHidden = emptyMessage.isEmpty
    }

    static func pill(_ text: String, color: NSColor = Theme.secondaryText) -> NSView {
        let pill = WorkflowPillView(color: color)
        let label = Style.label(text, size: 11, weight: .medium, color: color)
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.alignment = .center
        Style.fill(label, in: pill)
        pill.widthAnchor.constraint(equalToConstant: ceil(label.intrinsicContentSize.width) + 12).isActive = true
        pill.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return pill
    }

    static func review(_ alert: NSAlert, detail: String) {
        let text = NSTextView()
        text.string = detail
        text.isEditable = false
        text.font = TextLines.system(12)
        text.textContainerInset = NSSize(width: 6, height: 6)
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        let scroll = Style.scroll(text)
        scroll.frame = NSRect(
            x: 0, y: 0, width: 420, height: min(240, max(80, detail.components(separatedBy: "\n").count * 19)))
        alert.accessoryView = scroll
    }
}

private final class WorkflowPillView: NSView {
    private let tint: NSColor

    init(color: NSColor) {
        tint = color
        super.init(frame: .zero)
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    override func draw(_: NSRect) {
        tint.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
