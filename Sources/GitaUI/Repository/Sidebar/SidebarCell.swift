import AppKit
import GitaCore

/// One reusable cell for every sidebar row type; drawn with a few labels and an agent's mark. `SidebarCell+Rows`
/// configures it per row.
@MainActor
final class SidebarCell: NSTableCellView {
    enum Metrics {
        static let chevronWidth: CGFloat = 10
        static let iconWidth: CGFloat = 15
        static let markSide: CGFloat = 14
        static let spinnerSide: CGFloat = 12
        static let trailingInset: CGFloat = 12
        static let ruleInset: CGFloat = 14
        static let filterButtonSide: CGFloat = 16
        static let filterSymbolSize: CGFloat = 10.5
    }

    let chevron = NSImageView()
    let icon = NSImageView()
    let mark = AgentMarkView(side: Metrics.markSide)
    let title = Deck.label("")
    let subtitle = Deck.label("", font: Theme.caption, color: Theme.secondaryText)
    let trailing = Deck.label("", font: Theme.caption, color: Theme.secondaryText)
    let rule = FillView(color: Theme.separator)
    let spinner = NSProgressIndicator()
    lazy var leading = chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10)
    lazy var titleCenter = title.centerYAnchor.constraint(equalTo: centerYAnchor)
    lazy var titleTop = title.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 0)
    lazy var titleBeforeSpinner = title.trailingAnchor.constraint(
        lessThanOrEqualTo: spinner.leadingAnchor, constant: -6)
    private lazy var trailingToButtons = trailing.trailingAnchor.constraint(equalTo: filterButtons.leadingAnchor)
    /// Pin / show only / hide (branch rows): every button while the pointer is over the row, else only those on.
    private let filterKinds: [BranchFilters.Kind] = [.pin, .only, .hide]
    private let pin = SidebarCell.filterButton()
    private let only = SidebarCell.filterButton()
    private let hide = SidebarCell.filterButton()
    private lazy var filterButtons = NSStackView(views: [pin, only, hide])
    var marks: RepositorySidebarView.Marks?
    private(set) var hovering = false
    var onFilter: ((BranchFilters.Kind) -> Void)?
    /// A group row's open-or-close, for VoiceOver's press action (nil on rows that do not expand).
    var onPress: (() -> Void)?

    override func accessibilityPerformPress() -> Bool {
        guard let onPress else { return super.accessibilityPerformPress() }
        onPress()
        return true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        trailing.alignment = .right
        trailing.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        trailing.setContentHuggingPriority(.required, for: .horizontal)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true
        spinner.setAccessibilityLabel(String(localized: "Loading Repository"))
        filterButtons.spacing = 2
        filterButtons.orientation = .horizontal
        filterButtons.detachesHiddenViews = true
        filterButtons.setHuggingPriority(.required, for: .horizontal)
        for (index, button) in [pin, only, hide].enumerated() {
            button.target = self
            button.action = #selector(filterPressed(_:))
            button.tag = index
        }
        for view in [chevron, icon, mark, title, subtitle, trailing, rule, spinner, filterButtons] as [NSView] {
            addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate(constraints())
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    private func constraints() -> [NSLayoutConstraint] {
        [
            leading, chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: Metrics.chevronWidth),
            icon.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 5),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: Metrics.iconWidth),
            mark.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
            mark.centerYAnchor.constraint(equalTo: centerYAnchor),
            mark.widthAnchor.constraint(equalToConstant: Metrics.markSide),
            mark.heightAnchor.constraint(equalToConstant: Metrics.markSide),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7), titleCenter,
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -6),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: centerYAnchor, constant: 0),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -6),
            trailingToButtons, trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
            filterButtons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.trailingInset),
            filterButtons.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.trailingInset),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: Metrics.spinnerSide),
            spinner.heightAnchor.constraint(equalToConstant: Metrics.spinnerSide),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.ruleInset),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.ruleInset),
            rule.centerYAnchor.constraint(equalTo: centerYAnchor), rule.heightAnchor.constraint(equalToConstant: 1),
        ]
    }

    private static func filterButton() -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.setButtonType(.momentaryChange)
        button.isHidden = true
        button.widthAnchor.constraint(equalToConstant: Metrics.filterButtonSide).isActive = true
        button.heightAnchor.constraint(equalToConstant: Metrics.filterButtonSide).isActive = true
        return button
    }

    @objc private func filterPressed(_ sender: NSButton) {
        guard filterKinds.indices.contains(sender.tag) else { return }
        onFilter?(filterKinds[sender.tag])
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with _: NSEvent) { setHovering(true) }
    override func mouseExited(with _: NSEvent) { setHovering(false) }

    func setHovering(_ value: Bool) {
        hovering = value
        updateFilterButtons()
    }

    /// One filter button: its symbol and title while on and off.
    private struct FilterButton {
        var on: Bool
        var symbol: String
        var onSymbol: String
        var title: String
        var onTitle: String
        var available = true
    }

    func updateFilterButtons() {
        guard let marks, marks.filterable else {
            for button in [pin, only, hide] { button.isHidden = true }
            trailingToButtons.constant = 0
            return
        }
        show(
            pin,
            FilterButton(
                on: marks.pinned, symbol: "pin", onSymbol: "pin.fill", title: String(localized: "Pin to Top"),
                onTitle: String(localized: "Unpin")))
        show(
            only,
            FilterButton(
                on: marks.only, symbol: "line.3.horizontal.decrease", onSymbol: "line.3.horizontal.decrease",
                title: String(localized: "Show Only This Branch"),
                onTitle: String(localized: "Stop Showing Only This Branch")))
        show(
            hide,
            FilterButton(
                on: marks.hidden, symbol: "eye", onSymbol: "eye.slash", title: String(localized: "Hide in Graph"),
                onTitle: String(localized: "Show in Graph"), available: marks.hideable || marks.hidden))
        trailingToButtons.constant = [pin, only, hide].contains { !$0.isHidden } ? -4 : 0
    }

    private func show(_ button: NSButton, _ spec: FilterButton) {
        button.isHidden = !spec.available || !(spec.on || hovering)
        button.image = Deck.symbol(
            spec.on ? spec.onSymbol : spec.symbol, size: Metrics.filterSymbolSize,
            weight: spec.on ? .semibold : .regular, color: spec.on ? Theme.text : Theme.tertiaryText)
        let title = spec.on ? spec.onTitle : spec.title
        button.toolTip = title
        button.setAccessibilityLabel(title)
    }

    // MARK: Reuse

    func isChevronHit(at pointInCell: NSPoint) -> Bool {
        guard !chevron.isHidden, bounds.contains(pointInCell) else { return false }
        let hitMinX = max(0, chevron.frame.minX - 6)
        let hitMaxX = chevron.frame.maxX + 4
        return pointInCell.x >= hitMinX && pointInCell.x <= hitMaxX
    }

    func setChevron(_ expansion: RepositorySidebarView.Expansion) {
        let symbol: String? =
            switch expansion {
            case .none: nil
            case .collapsed: "chevron.right"
            case .expanded: "chevron.down"
            }
        chevron.setSymbol(symbol, size: 9, weight: .semibold, color: Theme.tertiaryText)
        chevron.isHidden = expansion == .none
        setAccessibilityExpanded(expansion == .expanded)
    }

    func showSpinner() {
        trailing.isHidden = true
        spinner.isHidden = false
        titleBeforeSpinner.isActive = true
        spinner.startAnimation(nil)
    }

    func reset() {
        if !spinner.isHidden {
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            titleBeforeSpinner.isActive = false
        }
        rule.isHidden = true
        mark.isHidden = true
        mark.agent = nil
        icon.isHidden = false
        subtitle.isHidden = true
        trailing.isHidden = false
        titleTop.isActive = false
        titleCenter.isActive = true
        title.font = Theme.body
        title.textColor = Theme.text
        trailing.textColor = Theme.secondaryText
        title.lineBreakMode = .byTruncatingTail
        trailing.lineBreakMode = .byTruncatingTail
        trailing.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        title.attributedStringValue = NSAttributedString(string: "")
        setAccessibilityLabel(nil)
        marks = nil
        // A recycled cell under a still pointer gets no enter event: read where the pointer is.
        if let window { hovering = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) }
    }
}
