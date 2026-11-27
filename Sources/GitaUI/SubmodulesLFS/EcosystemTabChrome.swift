import AppKit

/// Shared table, banner, and card chrome for `SubmodulesTabView` and `LFSTabView`.
@MainActor
enum EcosystemTabChrome {
    @MainActor
    final class TableCardSurface {
        let card: FillView
        let scroll: NSScrollView
        let emptyBox: NSStackView
        let emptyIcon: NSImageView
        let emptyLabel: NSTextField

        init(
            card: FillView, scroll: NSScrollView, emptyBox: NSStackView, emptyIcon: NSImageView, emptyLabel: NSTextField
        ) {
            self.card = card
            self.scroll = scroll
            self.emptyBox = emptyBox
            self.emptyIcon = emptyIcon
            self.emptyLabel = emptyLabel
        }

        func showEmpty(_ message: String, symbol: String, isError: Bool = false) {
            emptyIcon.setSymbol(
                symbol, size: 24, weight: .regular, color: isError ? Theme.failure : Theme.tertiaryText)
            emptyLabel.stringValue = message
            emptyLabel.textColor = isError ? Theme.failure : Theme.secondaryText
            let show = !message.isEmpty
            emptyBox.isHidden = !show
            scroll.isHidden = show
        }

        func applyTheme() {
            card.color = Theme.window
            card.borderColor = Theme.separator
        }
    }

    static func configureTable(
        _ table: NSTableView,
        dataSource: any NSTableViewDataSource,
        delegate: any NSTableViewDelegate,
        menuDelegate: any NSMenuDelegate,
        accessibilityLabel: String
    ) {
        table.style = .fullWidth
        table.rowHeight = 40
        table.intercellSpacing = NSSize(width: 8, height: 2)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.backgroundColor = .clear
        table.dataSource = dataSource
        table.delegate = delegate
        table.allowsEmptySelection = true
        table.setAccessibilityLabel(accessibilityLabel)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = menuDelegate
        table.menu = menu
    }

    static func configureBanner(
        _ banner: FillView, icon: NSImageView, label: NSTextField, tint: NSColor, textColor: NSColor
    ) {
        banner.cornerRadius = 8
        banner.color = tint.withAlphaComponent(0.12)
        banner.borderColor = tint.withAlphaComponent(0.32)
        banner.isHidden = true
        icon.setAccessibilityElement(false)
        icon.setSymbol("exclamationmark.triangle.fill", size: 12.5, weight: .semibold, color: textColor)
        label.textColor = textColor
        let row = Deck.hstack([icon, label], spacing: 8)
        Deck.pin(row, in: banner, insets: NSEdgeInsets(top: 7, left: 10, bottom: 7, right: 10))
    }

    static func layout(
        in host: NSView,
        header: NSView,
        statusBanner: NSView,
        table: NSTableView,
        emptySymbol: String,
        emptyWidth: CGFloat
    ) -> TableCardSurface {
        let scroll = Style.scroll(table)
        scroll.drawsBackground = false
        let emptyIcon = Deck.icon(emptySymbol, size: 24, weight: .regular, color: Theme.tertiaryText)
        emptyIcon.setAccessibilityElement(false)
        let emptyLabel = Deck.wrapping("", font: Theme.body, color: Theme.secondaryText)
        emptyLabel.alignment = .center
        emptyLabel.widthAnchor.constraint(lessThanOrEqualToConstant: emptyWidth).isActive = true
        let emptyBox = Deck.vstack([emptyIcon, emptyLabel], spacing: 8)
        emptyBox.alignment = .centerX
        let card = WorkflowPageView.makeTableCard(scroll: scroll, emptyBox: emptyBox, radius: 10)
        let cardWrapper = NSView()
        Deck.pin(card, in: cardWrapper, insets: NSEdgeInsets(top: 10, left: 18, bottom: 12, right: 18))
        cardWrapper.setContentHuggingPriority(.defaultLow, for: .vertical)
        cardWrapper.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        let stack = Deck.vstack([header, statusBanner, cardWrapper], spacing: 0)
        Deck.pin(stack, in: host)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        statusBanner.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36).isActive = true
        cardWrapper.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        return TableCardSurface(
            card: card, scroll: scroll, emptyBox: emptyBox, emptyIcon: emptyIcon, emptyLabel: emptyLabel)
    }
}
