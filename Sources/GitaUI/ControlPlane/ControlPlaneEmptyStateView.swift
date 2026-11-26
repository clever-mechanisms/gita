import AppKit

@MainActor
final class ControlPlaneEmptyStateView: NSView {
    private let spinner = NSProgressIndicator()
    private let message = Deck.wrapping("", color: Theme.secondaryText)
    private let action: PartsButton
    private var delay: Task<Void, Never>?

    init(id: String) {
        action = ControlPlaneViews.action(String(localized: "Retry"), symbol: "arrow.clockwise", id: id + ".retry") {}
        super.init(frame: .zero)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let stack = Deck.vstack([spinner, message, action], spacing: 8)
        stack.alignment = .centerX
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
        ])
        message.alignment = .center
        message.setAccessibilityIdentifier("controlPlane." + id + ".message")
    }
    required init?(coder _: NSCoder) { nil }
    deinit { delay?.cancel() }

    func show(_ text: String, loading: Bool = false, retry: (() -> Void)? = nil) {
        delay?.cancel()
        isHidden = false
        spinner.stopAnimation(nil)
        message.stringValue = text
        message.textColor = retry == nil ? Theme.secondaryText : Theme.failure
        action.isHidden = retry == nil
        action.onClick = retry
        if loading && !Deck.reduceMotion {
            delay = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                if !Task.isCancelled { self?.spinner.startAnimation(nil) }
            }
        }
    }
    func hide() {
        delay?.cancel()
        spinner.stopAnimation(nil)
        isHidden = true
    }
}

/// Native row selection, focus and up/down navigation shared by all three workspace lists.
@MainActor
final class WorkspaceRows: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private final class Row: NSTableRowView {
        override func drawSelection(in _: NSRect) {
            Theme.rowSelection.setFill()
            bounds.fill()
        }
        override func drawBackground(in dirtyRect: NSRect) {
            if hovering && !isSelected {
                Deck.hoverFill.setFill()
                bounds.fill()
            } else {
                super.drawBackground(in: dirtyRect)
            }
        }
        private var hovering = false
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            replaceHoverTrackingArea()
        }
        override func mouseEntered(with _: NSEvent) {
            hovering = true
            needsDisplay = true
        }
        override func mouseExited(with _: NSEvent) {
            hovering = false
            needsDisplay = true
        }
    }

    private final class Table: NSTableView {
        var open: ((Int) -> Void)?
        var rowMenu: ((Int) -> NSMenu?)?

        override func keyDown(with event: NSEvent) {
            if let open, selectedRow >= 0, KeyPress.isPlain(event),
                [KeyPress.returnKey, KeyPress.keypadEnter].contains(event.keyCode)
            {
                open(selectedRow)
            } else {
                super.keyDown(with: event)
            }
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            guard let rowMenu else { return super.menu(for: event) }
            let index = row(at: convert(event.locationInWindow, from: nil))
            guard index >= 0 else { return nil }
            selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            return rowMenu(index)
        }
    }

    private let table = Table()
    private let cellID = NSUserInterfaceItemIdentifier("WorkspaceRowCell")
    let placeholder: ControlPlaneEmptyStateView
    private var count = 0
    private var cell: ((Int) -> NSView)?
    init(id: String, title: String, height: CGFloat) {
        placeholder = ControlPlaneEmptyStateView(id: id)
        super.init(frame: .zero)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = Theme.window
        table.rowHeight = height
        table.intercellSpacing = NSSize(width: 0, height: 4)
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.focusRingType = .default
        ControlPlaneViews.identify(table, id + ".table", title)
        Deck.pin(Style.scroll(table), in: self)
        Deck.pin(placeholder, in: self)
    }
    required init?(coder _: NSCoder) { nil }
    func configureActions(open: @escaping (Int) -> Void, menu: @escaping (Int) -> NSMenu?) {
        table.open = open
        table.rowMenu = menu
        table.target = self
        table.doubleAction = #selector(openClickedRow)
    }

    @objc private func openClickedRow() {
        if table.clickedRow >= 0 { table.open?(table.clickedRow) }
    }
    func show(count: Int, cell: @escaping (Int) -> NSView) {
        placeholder.hide()
        self.count = count
        self.cell = cell
        table.reloadData()
    }
    func message(_ text: String, loading: Bool = false, retry: (() -> Void)? = nil) {
        show(count: 0) { _ in NSView() }
        placeholder.show(text, loading: loading, retry: retry)
    }
    func numberOfRows(in _: NSTableView) -> Int { count }
    func tableView(_: NSTableView, rowViewForRow _: Int) -> NSTableRowView? { Row() }
    func tableView(_: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < count, let content = cell?(row) else { return nil }
        let view = table.makeView(withIdentifier: cellID, owner: self) as? NSTableCellView ?? NSTableCellView()
        view.identifier = cellID
        view.subviews.forEach { $0.removeFromSuperview() }
        Deck.pin(content, in: view, insets: NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8))
        return view
    }
}
