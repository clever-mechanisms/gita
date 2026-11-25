import AppKit
import GitaCore

/// Welcome Launchpad layout and row views.
extension WelcomeView {
    func buildLayout() {
        let brand = buildBrandHeader()
        let leftColumn = buildLeftColumn()
        let recentCard = buildRecentCard()
        recentCard.setAccessibilityIdentifier("welcome.recentCard")
        let columns = NSView()
        columns.translatesAutoresizingMaskIntoConstraints = false
        for child in [leftColumn, recentCard] {
            columns.addSubview(child)
            child.translatesAutoresizingMaskIntoConstraints = false
        }

        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        for child in [brand, columns] {
            root.addSubview(child)
            child.translatesAutoresizingMaskIntoConstraints = false
        }
        let leftWidth = leftColumn.widthAnchor.constraint(equalToConstant: Self.startColumnWidth)
        leftWidth.priority = .init(740)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalMargin),
            root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalMargin),
            root.topAnchor.constraint(equalTo: topAnchor, constant: Self.topMargin),
            root.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.bottomMargin),
            brand.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            brand.topAnchor.constraint(equalTo: root.topAnchor),
            columns.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            columns.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            columns.topAnchor.constraint(equalTo: brand.bottomAnchor, constant: 26),
            columns.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            leftColumn.leadingAnchor.constraint(equalTo: columns.leadingAnchor),
            leftColumn.topAnchor.constraint(equalTo: columns.topAnchor),
            leftColumn.bottomAnchor.constraint(equalTo: columns.bottomAnchor),
            leftWidth,
            leftColumn.widthAnchor.constraint(lessThanOrEqualToConstant: Self.startColumnWidth),
            recentCard.leadingAnchor.constraint(
                equalTo: leftColumn.trailingAnchor, constant: RepositoryLayout.welcomeSpacing),
            recentCard.trailingAnchor.constraint(equalTo: columns.trailingAnchor),
            recentCard.topAnchor.constraint(equalTo: columns.topAnchor),
            recentCard.bottomAnchor.constraint(equalTo: columns.bottomAnchor),
        ])
    }

    private func buildLeftColumn() -> NSView {
        let startHeader = Deck.sectionTitle(String(localized: "Start"))
        startStack.alignment = .leading
        let spacer = Deck.spacer()
        spacer.setContentHuggingPriority(.init(1), for: .vertical)
        spacer.setContentCompressionResistancePriority(.init(1), for: .vertical)
        let stack = Deck.vstack([startHeader, startStack, dropZone, spacer, footerStack], spacing: 16)
        stack.alignment = .leading
        startStack.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        dropZone.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Scrollable so compact windows and an open terminal panel are never blocked by the column's natural height.
        let scroll = Self.makeScrollView()
        let document = Deck.document(in: scroll)
        Deck.pin(stack, in: document)
        document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor).isActive = true
        return scroll
    }

    private static func makeScrollView() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        return scroll
    }

    private func buildBrandHeader() -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityIdentifier("welcome.logo")
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 56),
            icon.heightAnchor.constraint(equalToConstant: 56),
        ])
        let title = Style.label("Gitā", size: RepositoryLayout.welcomeTitleSize, weight: .semibold, color: Theme.text)
        let subtitle = Style.label(
            String(localized: "Native Git history, PRs, deploys & agents."), size: 14, color: Theme.secondaryText)
        let text = Deck.vstack([title, subtitle], spacing: 4)
        return Deck.hstack([icon, text], spacing: 14)
    }

    private func buildRecentCard() -> NSView {
        let card = FillView(color: Theme.inset)
        card.cornerRadius = 12
        card.borderColor = Theme.separator
        let header = buildRecentHeader()
        let scroll = Self.makeScrollView()
        let document = Deck.document(in: scroll)
        recentEmpty.alignment = .center
        let content = Deck.vstack([recentStack, recentEmpty], spacing: 8)
        content.alignment = .leading
        Deck.pin(content, in: document, insets: NSEdgeInsets(top: 6, left: 0, bottom: 8, right: 0))
        for child in content.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }

        let separator = Deck.separator()
        for child in [header, separator, scroll] {
            card.addSubview(child)
            child.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            header.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            separator.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            separator.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            separator.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
        ])
        return card
    }

    private func buildRecentHeader() -> NSView {
        filterField.placeholderString = String(localized: "Filter repositories…")
        filterField.controlSize = .regular
        filterField.font = Theme.body
        filterField.sendsSearchStringImmediately = true
        filterField.target = self
        filterField.action = #selector(filterChanged)
        filterField.setAccessibilityLabel(String(localized: "Filter repositories"))
        filterField.setAccessibilityIdentifier("welcome.filter")
        recentCount.textColor = Theme.tertiaryText
        recentCount.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        let recentTitle = Deck.sectionTitle(String(localized: "Recent Repositories"))
        recentTitle.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        for child in [recentTitle, recentCount, filterField] {
            header.addSubview(child)
            child.translatesAutoresizingMaskIntoConstraints = false
        }
        let filterWidth = filterField.widthAnchor.constraint(equalToConstant: 260)
        filterWidth.priority = .init(700)
        NSLayoutConstraint.activate([
            recentTitle.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            recentTitle.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            recentCount.leadingAnchor.constraint(equalTo: recentTitle.trailingAnchor, constant: 8),
            recentCount.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            filterField.leadingAnchor.constraint(greaterThanOrEqualTo: recentCount.trailingAnchor, constant: 12),
            filterField.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            filterField.topAnchor.constraint(equalTo: header.topAnchor),
            filterField.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            filterWidth,
            filterField.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
        ])
        return header
    }
}

@MainActor
final class WelcomeDropZoneView: NSView {
    var isHighlighted = false { didSet { if isHighlighted != oldValue { needsDisplay = true } } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let label = Style.label(
            String(localized: "Drop a folder here to open it"), size: 13, color: Theme.secondaryText)
        label.alignment = .center
        addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 148),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("WelcomeDropZoneView is built in code") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
        let dash: [CGFloat] = [5, 4]
        path.setLineDash(dash, count: dash.count, phase: 0)
        path.lineWidth = isHighlighted ? 1.5 : 1
        (isHighlighted ? Theme.accent : Theme.separator).setStroke()
        if isHighlighted {
            Theme.accent.withAlphaComponent(0.08).setFill()
            path.fill()
        }
        path.stroke()
    }
}

@MainActor
final class WelcomeRecentRow: RowView {
    init(entry: WelcomePresenter.RecentEntry, onOpen: @escaping () -> Void, onRemove: @escaping () -> Void) {
        super.init(frame: .zero)
        let title = Deck.label(entry.name, font: TextLines.system(14.5, weight: .semibold))
        let subtitle = Style.label(entry.displayPath, size: 12.5, color: Theme.secondaryText)
        subtitle.lineBreakMode = .byTruncatingMiddle
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var topItems: [NSView] = [title]
        var bottomItems: [NSView] = [subtitle]
        var rightItems: [NSView] = []
        switch entry.status {
        case .loading:
            rightItems.append(Style.label("…", size: 12.5, color: Theme.tertiaryText))
        case .missing:
            onClick = nil
            let missing = Deck.label(
                String(localized: "⚠ Missing"), font: TextLines.system(12.5, weight: .semibold), color: Theme.failure)
            let remove = PartsButton.link(String(localized: "Remove from list"), size: 12, action: onRemove)
            rightItems.append(contentsOf: [missing, remove])
        case .ready(let summary):
            onClick = onOpen
            if let branch = summary.branch, !branch.isEmpty {
                let branchLabel = Deck.label(branch, font: Theme.mono, color: Theme.secondaryText)
                branchLabel.lineBreakMode = .byTruncatingTail
                topItems.append(branchLabel)
            }
            if let tool = summary.agentTool, let state = summary.agentState {
                let mark = AgentMarkView(side: 14)
                mark.tool = tool
                mark.state = state
                bottomItems.append(mark)
            }
            if let dateText = WelcomePresenter.relativeDateText(summary.lastUpdated) {
                bottomItems.append(Style.label(dateText, size: 12.5, color: Theme.tertiaryText))
            }
            let badgeColor = summary.isClean ? Theme.success : Theme.needsInput
            let badgeText = WelcomePresenter.badgeText(for: summary)
            rightItems.append(
                Deck.label(badgeText, font: TextLines.system(12.5, weight: .semibold), color: badgeColor))
        }
        for item in rightItems {
            item.setContentCompressionResistancePriority(.required, for: .horizontal)
            item.setContentHuggingPriority(.required, for: .horizontal)
        }
        let topRow = Deck.hstack(topItems, spacing: 10)
        let bottomRow = Deck.hstack(bottomItems, spacing: 10)
        let left = Deck.vstack([topRow, bottomRow], spacing: 4)
        left.alignment = .leading
        let right = Deck.hstack(rightItems, spacing: 10)
        for child in [left, right] {
            addSubview(child)
            child.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            left.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            left.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11),
            right.leadingAnchor.constraint(greaterThanOrEqualTo: left.trailingAnchor, constant: 16),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            right.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityLabel(entry.name)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("WelcomeRecentRow is built in code") }
}
