import AppKit

/// Shared table and layout scaffolding for `SubmodulesTabView` and `LFSTabView`.
@MainActor
enum EcosystemTabChrome {
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
        table.backgroundColor = Theme.window
        table.dataSource = dataSource
        table.delegate = delegate
        table.allowsEmptySelection = true
        table.setAccessibilityLabel(accessibilityLabel)
        let menu = NSMenu()
        menu.delegate = menuDelegate
        table.menu = menu
    }

    static func layout(
        in host: NSView,
        header: NSView,
        statusBanner: NSView,
        table: NSTableView,
        emptyLabel: NSView,
        emptyWidth: CGFloat
    ) {
        let divider = Deck.separator()
        let scroll = Style.scroll(table)
        let stack = Deck.vstack([header, divider, statusBanner, scroll], spacing: 0)
        Deck.pin(stack, in: host)
        for view in [header, divider, scroll] as [NSView] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        statusBanner.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualToConstant: emptyWidth),
        ])
    }
}
