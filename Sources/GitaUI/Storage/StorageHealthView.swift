import AppKit

@MainActor
final class StorageHealthView: NSScrollView {
    init(
        summary: StorageHealthSummaryModel? = nil, cards: [StorageHealthCardModel], actionState: HealthActionState,
        openGlobalSettings: (() -> Void)? = nil,
        perform: @escaping (StorageHealthAction) -> Void
    ) {
        super.init(frame: .zero)
        let document = StorageStyle.configureScrollView(self)
        let stack = Deck.vstack([], spacing: 16)
        Deck.pin(stack, in: document, insets: NSEdgeInsets(top: 16, left: 18, bottom: 20, right: 18))

        if let banner = StorageStyle.banner(actionState) { StorageStyle.addFullWidth(banner, to: stack) }
        if let summary {
            StorageStyle.addFullWidth(
                makeSummaryCard(summary, openGlobalSettings: openGlobalSettings, perform: perform), to: stack)
        }
        addSection(
            title: String(localized: "Performance"),
            cards: cards.filter { $0.section == .performance }, in: stack, perform: perform)
        addSection(
            title: String(localized: "Maintenance"),
            cards: cards.filter { $0.section == .maintenance }, in: stack, perform: perform)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("StorageHealthView is built in code") }

    private func makeSummaryCard(
        _ summary: StorageHealthSummaryModel, openGlobalSettings: (() -> Void)?,
        perform: @escaping (StorageHealthAction) -> Void
    ) -> NSView {
        let allEnabled = summary.enabledCount == summary.totalCount
        let card = StorageStyle.card(cornerRadius: 10)
        let badge = StorageStyle.iconBadge(
            allEnabled ? "checkmark.shield.fill" : "stethoscope",
            tint: allEnabled ? Theme.success : Theme.accent,
            boxSize: 36, symbolSize: 17, cornerRadius: 8)
        let headline = Deck.label(summary.headline, font: TextLines.system(14, weight: .semibold))
        let scopePill = StorageStyle.pill(summary.scopeBadge, fill: Theme.control, textColor: Theme.secondaryText)
        let headlineRow = Deck.hstack([headline, scopePill], spacing: 8)
        let subtitle = Deck.wrapping(summary.subtitle, font: Theme.caption, color: Theme.secondaryText)
        let textColumn = Deck.vstack([headlineRow, subtitle], spacing: 3)

        var trailingViews = [NSView]()
        if let openGlobalSettings {
            trailingViews.append(
                StorageStyle.actionButton(
                    String(localized: "Global Defaults…"), symbol: "gearshape", style: .quiet,
                    accessibility: String(localized: "Global Defaults…"), onClick: openGlobalSettings))
        }
        trailingViews.append(makeSummaryStatusControl(summary.status, perform: perform))
        let trailing = Deck.hstack(trailingViews, spacing: 8)

        let row = Deck.hstack([badge, textColumn, Deck.spacer(), trailing], spacing: 12)
        Deck.pin(row, in: card, insets: NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16))
        return card
    }

    private func makeSummaryStatusControl(
        _ status: StorageHealthSummaryModel.Status, perform: @escaping (StorageHealthAction) -> Void
    ) -> NSView {
        switch status {
        case .recommend(let action):
            StorageStyle.actionButton(
                action.buttonTitle, symbol: "sparkles", style: .accent, accessibility: action.title
            ) { perform(action) }
        case .optimized:
            StorageStyle.statusPill(String(localized: "Optimized"), tone: .positive)
        case .updating:
            StorageStyle.statusPill(String(localized: "Updating…"), tone: .neutral)
        }
    }

    private func addSection(
        title: String, cards: [StorageHealthCardModel], in stack: NSStackView,
        perform: @escaping (StorageHealthAction) -> Void
    ) {
        guard !cards.isEmpty else { return }
        let sectionHeader = Deck.sectionTitle(title)
        let card = StorageStyle.card(cornerRadius: 10)
        let rows = Deck.vstack([], spacing: 0)
        Deck.pin(rows, in: card)

        for (index, model) in cards.enumerated() {
            if index > 0 { StorageStyle.addFullWidth(makeInsetDivider(), to: rows) }
            StorageStyle.addFullWidth(makeSettingRow(model, perform: perform), to: rows)
        }

        let group = Deck.vstack([sectionHeader, card], spacing: 6)
        StorageStyle.addFullWidth(group, to: stack)
        card.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
    }

    private func makeSettingRow(
        _ model: StorageHealthCardModel, perform: @escaping (StorageHealthAction) -> Void
    ) -> NSView {
        let icon = StorageStyle.iconBadge(
            model.symbol, tint: StorageStyle.toneColor(model.iconTone),
            boxSize: 30, symbolSize: 14, cornerRadius: 7)
        let title = Deck.label(model.title, font: Theme.bodyEmphasis)
        let status = StorageStyle.statusPill(model.statusText, tone: model.statusTone)
        var titleViews: [NSView] = [title, status]
        if let scope = model.scopeOrigin {
            let fill = scope.isInherited ? Theme.accent.withAlphaComponent(0.12) : Theme.control
            let color = scope.isInherited ? Theme.accent : Theme.secondaryText
            titleViews.append(StorageStyle.pill(scope.label, fill: fill, textColor: color))
        }
        let titleRow = Deck.hstack(titleViews, spacing: 8)
        let detail = Deck.wrapping(model.detail, font: Theme.caption, color: Theme.secondaryText)

        var textItems: [NSView] = [titleRow, detail]
        if !model.statPills.isEmpty {
            let pills = model.statPills.map {
                StorageStyle.pill($0, fill: Theme.control, textColor: Theme.secondaryText, monospacedDigits: true)
            }
            textItems.append(Deck.hstack(pills, spacing: 6))
        }
        let textColumn = Deck.vstack(textItems, spacing: 4)
        textColumn.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let controls = makeRowControls(model, perform: perform)
        let container = NSView()
        let row = Deck.hstack([icon, textColumn, Deck.spacer(), controls], spacing: 12)
        Deck.pin(row, in: container, insets: NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14))
        return container
    }

    private func makeRowControls(
        _ model: StorageHealthCardModel, perform: @escaping (StorageHealthAction) -> Void
    ) -> NSView {
        var views = [NSView]()
        if let secondary = model.secondaryToggle {
            let toggle = AccentSwitch(accessibility: secondary.accessibilityLabel) { _ in
                perform(secondary.action)
            }
            toggle.setOn(secondary.isOn)
            toggle.isEnabled = model.enabled
            toggle.toolTip = secondary.accessibilityLabel
            views.append(toggle)
        }
        let primary: NSControl
        switch model.control {
        case .toggle(let on):
            let toggle = AccentSwitch(accessibility: model.title) { _ in perform(model.action) }
            toggle.setOn(on)
            primary = toggle
        case .button:
            primary = StorageStyle.actionButton(
                model.action.buttonTitle, symbol: model.buttonSymbol, style: .quiet, accessibility: model.action.title
            ) { perform(model.action) }
        }
        primary.isEnabled = model.enabled
        views.append(primary)
        return Deck.hstack(views, spacing: 10)
    }

    private func makeInsetDivider() -> NSView {
        let holder = NSView()
        let line = Deck.separator()
        Deck.pin(line, in: holder, insets: NSEdgeInsets(top: 0, left: 56, bottom: 0, right: 0))
        return holder
    }
}
