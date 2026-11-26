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

/// Shared native window chrome for repository utilities (Cleanup Assistant, Stacked Branches):
/// a `Theme.toolbar` header bar with a hero icon badge, an optional controls strip, a bordered card table,
/// and a `Theme.toolbar` footer bar with an accent action button.
@MainActor
final class WorkflowWindowContent {
    private enum Metrics {
        static let defaultSize = NSSize(width: 860, height: 520)
        static let minSize = NSSize(width: 700, height: 380)
        static let rowHeight: CGFloat = 48
        static let horizontalInset: CGFloat = 18
        static let cardRadius: CGFloat = 10
    }

    let window: NSWindow
    let table = WorkflowTableView()
    let headerTrailing = Deck.hstack([], spacing: 8)
    let controls = Deck.hstack([], spacing: 6)
    let subtitle = Deck.caption("")
    let summary = Deck.label("", font: .monospacedDigitSystemFont(ofSize: 12, weight: .medium))
    let status = Deck.label("", font: Theme.caption, color: Theme.secondaryText)
    let empty = Deck.wrapping("", font: Theme.body, color: Theme.secondaryText)
    let refresh: PartsButton
    let action: PartsButton
    private let emptyIcon = Deck.icon("tray", size: 24, weight: .regular, color: Theme.tertiaryText)
    private let emptyBox: NSStackView
    private let scroll: NSScrollView
    private let controlsWrapper = NSView()
    private let headerBar = FillView(color: Theme.toolbar)
    private let footerBar = FillView(color: Theme.toolbar)
    private let tableCard = FillView(color: Theme.window)
    private let statusIcon = Deck.icon("info.circle", size: 12, weight: .regular, color: Theme.tertiaryText)
    private let column = NSTableColumn(identifier: .init("workflow.row"))
    private var themeObserver: NSObjectProtocol?

    init(
        title: String, repositoryName: String? = nil, symbol: String = "wand.and.stars",
        actionTitle: String, actionSymbol: String? = nil
    ) {
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Metrics.defaultSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = repositoryName.map { String(localized: "\(title) · \($0)") } ?? title
        window.minSize = Metrics.minSize
        window.isReleasedWhenClosed = false
        refresh = PartsButton.quiet(String(localized: "Refresh"), symbol: "arrow.clockwise") {}
        refresh.setAccessibilityIdentifier("workflow.refresh")
        refresh.fixedHeight = 26
        action = Self.makeActionButton(title: actionTitle, symbol: actionSymbol)
        emptyBox = Deck.vstack([emptyIcon, empty], spacing: 8)
        emptyBox.alignment = .centerX
        scroll = Style.scroll(table)
        scroll.drawsBackground = false
        configureTable(accessibilityTitle: title)
        let root = ThemedBackgroundView()
        let headerSection = buildHeader(title: title, symbol: symbol)
        let controlsSection = buildControls()
        let cardSection = buildTableCard()
        let footerSection = buildFooter()
        layoutRoot(
            root, header: headerSection, controls: controlsSection, card: cardSection, footer: footerSection)
        window.contentView = root
        window.center()
        observeTheme()
    }

    var showsControls: Bool {
        get { !controlsWrapper.isHidden }
        set { controlsWrapper.isHidden = !newValue }
    }

    func setActionTitle(_ title: String, symbol: String? = nil) {
        action.parts = Self.actionParts(title: title, symbol: symbol)
        action.setAccessibilityLabel(title)
    }

    func feedback(_ text: String, emptyMessage: String, emptySymbol: String = "tray", isError: Bool = false) {
        status.stringValue = text
        status.toolTip = text
        status.isHidden = text.isEmpty
        status.textColor = isError ? Theme.failure : Theme.secondaryText
        statusIcon.setSymbol(
            isError ? "exclamationmark.triangle.fill" : "info.circle", size: 12,
            color: isError ? Theme.failure : Theme.tertiaryText)
        emptyIcon.setSymbol(
            emptySymbol, size: 24, weight: .regular, color: isError ? Theme.failure : Theme.tertiaryText)
        empty.stringValue = emptyMessage
        empty.textColor = isError ? Theme.failure : Theme.secondaryText
        let showEmpty = !emptyMessage.isEmpty
        emptyBox.isHidden = !showEmpty
        scroll.isHidden = showEmpty
    }

    func stopObservingTheme() {
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
        themeObserver = nil
    }

    private func observeTheme() {
        themeObserver = NotificationCenter.default.addObserver(
            forName: .gitaThemeChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyTheme() }
        }
    }

    private func applyTheme() {
        window.backgroundColor = Theme.window
        headerBar.color = Theme.toolbar
        footerBar.color = Theme.toolbar
        tableCard.color = Theme.window
        tableCard.borderColor = Theme.separator
        table.reloadData()
    }

    private func configureTable(accessibilityTitle: String) {
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.rowHeight = Metrics.rowHeight
        table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.setAccessibilityLabel(accessibilityTitle)
    }

    private func buildHeader(title: String, symbol: String) -> NSView {
        let badge = StorageStyle.iconBadge(symbol, tint: Theme.accent, boxSize: 32, symbolSize: 15, cornerRadius: 8)
        let titleLabel = Deck.label(title, font: TextLines.system(14, weight: .semibold), color: Theme.text)
        let titles = Deck.vstack([titleLabel, subtitle], spacing: 2)
        headerTrailing.addArrangedSubview(refresh)
        let row = Deck.hstack([badge, titles, Deck.spacer(), headerTrailing], spacing: 12)
        Deck.pin(
            row, in: headerBar,
            insets: NSEdgeInsets(top: 12, left: Metrics.horizontalInset, bottom: 12, right: Metrics.horizontalInset))
        return headerBar
    }

    private func buildControls() -> NSView {
        Deck.pin(
            controls, in: controlsWrapper,
            insets: NSEdgeInsets(top: 12, left: Metrics.horizontalInset, bottom: 0, right: Metrics.horizontalInset))
        return controlsWrapper
    }

    private func buildTableCard() -> NSView {
        tableCard.borderColor = Theme.separator
        tableCard.cornerRadius = Metrics.cardRadius
        let clip = NSView()
        clip.wantsLayer = true
        clip.layer?.cornerRadius = Metrics.cardRadius - 1
        clip.layer?.masksToBounds = true
        Deck.pin(scroll, in: clip)
        Deck.pin(clip, in: tableCard, insets: NSEdgeInsets(top: 1, left: 1, bottom: 1, right: 1))
        empty.alignment = .center
        emptyBox.translatesAutoresizingMaskIntoConstraints = false
        tableCard.addSubview(emptyBox)
        NSLayoutConstraint.activate([
            emptyBox.centerXAnchor.constraint(equalTo: tableCard.centerXAnchor),
            emptyBox.centerYAnchor.constraint(equalTo: tableCard.centerYAnchor),
            emptyBox.widthAnchor.constraint(equalTo: tableCard.widthAnchor, constant: -64),
            empty.widthAnchor.constraint(equalTo: emptyBox.widthAnchor),
        ])
        let wrapper = NSView()
        Deck.pin(
            tableCard, in: wrapper,
            insets: NSEdgeInsets(top: 12, left: Metrics.horizontalInset, bottom: 12, right: Metrics.horizontalInset))
        return wrapper
    }

    private func buildFooter() -> NSView {
        status.isHidden = true
        statusIcon.setAccessibilityElement(false)
        let summaryLine = Deck.hstack([statusIcon, summary], spacing: 6)
        let left = Deck.vstack([summaryLine, status], spacing: 2)
        let row = Deck.hstack([left, Deck.spacer(), action], spacing: 12)
        Deck.pin(
            row, in: footerBar,
            insets: NSEdgeInsets(top: 10, left: Metrics.horizontalInset, bottom: 10, right: Metrics.horizontalInset))
        return footerBar
    }

    private func layoutRoot(
        _ root: NSView, header: NSView, controls: NSView, card: NSView, footer: NSView
    ) {
        let topDivider = Deck.separator()
        let bottomDivider = Deck.separator()
        let stack = Deck.vstack([header, topDivider, controls, card, bottomDivider, footer], spacing: 0)
        Deck.pin(stack, in: root)
        for view in [header, topDivider, controls, card, bottomDivider, footer] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        card.setContentHuggingPriority(.defaultLow, for: .vertical)
        card.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }

    private static func makeActionButton(title: String, symbol: String?) -> PartsButton {
        let button = PartsButton(actionParts(title: title, symbol: symbol), background: .accent, accessibility: title)
        button.fixedHeight = 28
        button.horizontalPadding = 12
        button.spacing = 6
        button.cornerRadius = 6
        button.setAccessibilityIdentifier("workflow.action")
        return button
    }

    private static func actionParts(title: String, symbol: String?) -> [PartsButton.Part] {
        var parts: [PartsButton.Part] = []
        if let symbol { parts.append(.symbol(symbol, color: Deck.onAccent, size: 11.5)) }
        parts.append(.text(title, font: TextLines.system(12, weight: .semibold), color: Deck.onAccent))
        return parts
    }

    static func wrapRow(_ content: NSView, insets: NSEdgeInsets, divider: Bool) -> NSView {
        let container = NSView()
        Deck.pin(content, in: container, insets: insets)
        if divider {
            let line = FillView(color: Theme.separator.withAlphaComponent(0.5))
            line.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(line)
            NSLayoutConstraint.activate([
                line.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
                line.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
                line.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                line.heightAnchor.constraint(equalToConstant: 1),
            ])
        }
        return container
    }

    static func pill(_ text: String, symbol: String? = nil, color: NSColor = Theme.secondaryText) -> NSView {
        let pill = FillView(color: color.withAlphaComponent(0.13))
        pill.borderColor = color.withAlphaComponent(0.28)
        pill.cornerRadius = 6
        let label = Deck.label(text, font: .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium), color: color)
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        var views: [NSView] = []
        if let symbol {
            let icon = Deck.icon(symbol, size: 9.5, weight: .semibold, color: color)
            icon.setAccessibilityElement(false)
            views.append(icon)
        }
        views.append(label)
        let stack = Deck.hstack(views, spacing: 4)
        Deck.pin(stack, in: pill, insets: NSEdgeInsets(top: 2.5, left: 6.5, bottom: 2.5, right: 6.5))
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
