import AppKit

/// The guide's measurements.
@MainActor
enum SetupGuideLayout {
    static let railWidth: CGFloat = 212
    static let contentInset: CGFloat = 30
    static let stepHeight: CGFloat = 32
}

/// The guide's controls: the rail of steps, the heading, the scrolling page, the footer, and what they change.
extension SetupGuideController {
    func button(_ title: String, id: String, symbol: String? = nil, action: Selector) -> NSButton {
        let button = Style.button(title, symbol: symbol, target: self, action: action)
        button.controlSize = .regular
        button.font = TextLines.system(13)
        button.setAccessibilityIdentifier("setup." + id)
        return button
    }

    func buildInterface() {
        guard let window else { return }
        let root = ThemedBackgroundView()
        window.contentView = root
        let rail = makeRail()
        let content = makeContent()
        for child in [rail, content] {
            root.addSubview(child)
            child.translatesAutoresizingMaskIntoConstraints = false
        }
        let inset = SetupGuideLayout.contentInset
        NSLayoutConstraint.activate([
            rail.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            rail.topAnchor.constraint(equalTo: root.topAnchor),
            rail.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            rail.widthAnchor.constraint(equalToConstant: SetupGuideLayout.railWidth),
            content.leadingAnchor.constraint(equalTo: rail.trailingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
        ])
        window.defaultButtonCell = nextButton.cell as? NSButtonCell
    }

    // MARK: Rail

    private func makeRail() -> NSView {
        let rail = ThemedBackgroundView()
        rail.color = Theme.sidebar
        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 44).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 44).isActive = true
        let name = Style.label("Gitā", size: 17, weight: .bold, color: Theme.text)
        let caption = Style.label(String(localized: "Setup"), size: 12, color: Theme.secondaryText)
        let brand = Style.stack([icon, Style.stack([name, caption], vertical: true, spacing: 0)], spacing: 10)
        let steps = NSStackView()
        steps.orientation = .vertical
        steps.alignment = .leading
        steps.spacing = 4
        steps.setAccessibilityIdentifier("setup.cards")
        for page in SetupGuideCard.allCases {
            let step = makeStep(page)
            steps.addArrangedSubview(step)
            step.widthAnchor.constraint(equalTo: steps.widthAnchor).isActive = true
        }
        let column = Style.stack([brand, steps], vertical: true, spacing: 26)
        steps.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        rail.addSubview(column)
        column.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: rail.leadingAnchor, constant: 16),
            column.trailingAnchor.constraint(equalTo: rail.trailingAnchor, constant: -16),
            column.topAnchor.constraint(equalTo: rail.topAnchor, constant: 26),
        ])
        return rail
    }

    private func makeStep(_ page: SetupGuideCard) -> SetupCardButton {
        let step = SetupCardButton(title: page.title, target: self, action: #selector(selectCard(_:)))
        step.tag = page.rawValue
        step.setButtonType(.momentaryChange)
        step.isBordered = false
        step.alignment = .left
        step.imagePosition = .imageLeading
        step.imageHugsTitle = true
        step.font = TextLines.system(13, weight: .medium)
        step.heightAnchor.constraint(equalToConstant: SetupGuideLayout.stepHeight).isActive = true
        step.setAccessibilityLabel(String(localized: "\(page.title) step"))
        step.setAccessibilityIdentifier("setup.card." + page.identifier)
        step.onArrow = { [weak self] amount in self?.moveCard(amount, focusSelector: true) }
        cardButtons.append(step)
        return step
    }

    /// The current step stands out; the steps before it are ticked.
    func updateRail() {
        for step in cardButtons {
            guard let page = SetupGuideCard(rawValue: step.tag) else { continue }
            step.isCurrent = page == card
            let done = page.rawValue < card.rawValue
            step.image = Deck.template(done ? "checkmark.circle.fill" : page.symbol, size: 13, weight: .medium)
            step.contentTintColor = page == card ? Theme.accentText : done ? Theme.success : Theme.secondaryText
            step.setAccessibilityValue(page == card ? String(localized: "current") : nil)
        }
    }

    // MARK: Content

    private func makeContent() -> NSView {
        heading.setAccessibilityIdentifier("setup.title")
        heading.setAccessibilityRole(.staticText)
        position.setAccessibilityIdentifier("setup.position")
        subtitle.font = TextLines.system(13)
        subtitle.textColor = Theme.secondaryText
        subtitle.setAccessibilityIdentifier("setup.subtitle")
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let header = Style.stack([heading, NSView(), position])
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        buildBody()
        let footer = makeFooter()
        let column = Style.stack([header, subtitle, bodyScroll, footer], vertical: true, spacing: 12)
        column.setCustomSpacing(18, after: subtitle)
        column.setCustomSpacing(16, after: bodyScroll)
        for view in [header, subtitle, bodyScroll, footer] {
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        bodyScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        bodyScroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return column
    }

    private func buildBody() {
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 16
        let document = FlippedView()
        document.addSubview(body)
        body.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        bodyScroll.documentView = document
        bodyScroll.hasVerticalScroller = true
        bodyScroll.autohidesScrollers = true
        bodyScroll.drawsBackground = false
        bodyScroll.borderType = .noBorder
        bodyScroll.scrollerStyle = .overlay
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: bodyScroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: bodyScroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: bodyScroll.contentView.widthAnchor),
            body.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            body.topAnchor.constraint(equalTo: document.topAnchor),
            body.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -4),
        ])
    }

    private func makeFooter() -> NSStackView {
        cancelButton.keyEquivalent = "\u{1b}"
        nextButton.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return Style.stack([cancelButton, spacer, backButton, nextButton])
    }

    /// − 100% + for the history zoom card.
    func zoomControl() -> NSView {
        zoomOut.toolTip = String(localized: "Zoom Out · ⌘−")
        zoomIn.toolTip = String(localized: "Zoom In · ⌘+")
        zoomValue.toolTip = String(localized: "Actual Size · ⌘0")
        zoomOut.setAccessibilityLabel(String(localized: "Reduce demo history zoom"))
        zoomIn.setAccessibilityLabel(String(localized: "Increase demo history zoom"))
        zoomValue.setAccessibilityLabel(String(localized: "Reset demo history zoom to 100 percent"))
        for button in [zoomOut, zoomIn] { button.imagePosition = .imageOnly }
        return Style.stack([zoomOut, zoomValue, zoomIn], spacing: 4)
    }

    // MARK: Choices

    @objc func selectCard(_ sender: SetupCardButton) {
        if let page = SetupGuideCard(rawValue: sender.tag) { show(page, focusSelector: true) }
    }
    @objc func back() { moveCard(-1, focusSelector: false) }
    @objc func reduceZoom() { changeZoom(to: draft.historyZoomPercent - HistoryZoom.step) }
    @objc func increaseZoom() { changeZoom(to: draft.historyZoomPercent + HistoryZoom.step) }
    @objc func resetZoom() { changeZoom(to: HistoryZoom.actual) }
    private func changeZoom(to percent: Int) {
        guard card == .history, isOpen else { return }
        draft.historyZoomPercent = HistoryZoom.bounded(percent)
        changedChoice()
    }
    /// A tile's switch: the draft follows; the scene shows it at once.
    func setChoice(_ preference: Preference, _ on: Bool) {
        guard isOpen else { return }
        draft[preference] = on
        changedChoice()
    }
    @objc func toggleDetails() {
        guard card == .history else { return }
        setChoice(.showsHistoryDetails, !draft[.showsHistoryDetails])
    }
    private func changedChoice() {
        lastInteraction = Date()
        syncChoices()
    }
    func handleHistoryShortcut(_ key: String) -> Bool {
        guard card == .history, isOpen else { return false }
        switch key {
        case "+", "=": increaseZoom()
        case "-": reduceZoom()
        case "0": resetZoom()
        case "d": toggleDetails()
        default: return false
        }
        return true
    }
}
