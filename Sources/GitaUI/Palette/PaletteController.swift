import AppKit

/// The command palette (⌘K by default): a floating search over everything the app can do and go to. Commands,
/// branches, pull requests, workflow runs, deployments, repositories and commits, in sections; typing filters and
/// ranks them, Tab narrows to one kind, ↑ ↓ move, Return runs the selected one, ⌘N starts a new branch named after
/// what is typed, Escape or clicking elsewhere closes it. `PaletteState` decides what is listed.
@MainActor
final class PaletteController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    static let size = NSSize(width: 640, height: 448)
    private static let rowHeight: CGFloat = 34
    private static let headerHeight: CGFloat = 26
    private static let emptyLabelTop: CGFloat = 48

    let panel = PalettePanel(
        contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
    let field = PaletteField()
    let table = NSTableView()
    let scopeBar = PaletteScopeBar()
    let emptyLabel = Style.label(String(localized: "No results"), size: 13, color: Theme.secondaryText)
    private(set) var state: PaletteState
    var onChoose: ((PaletteItem) -> Void)?
    /// ⌘N: a new branch, suggested the name typed so far.
    var onNewBranch: ((String) -> Void)?
    /// Return on an item that cannot run now.
    var onUnavailable: (() -> Void)?
    /// Search input changed (feeds Paste-Anything Teleport banner).
    var onQueryChange: ((String) -> Void)?
    /// The palette dismissed.
    var onClose: (() -> Void)?
    private let teleportSlot = Deck.vstack([], spacing: 0)

    init(scope: PaletteKind? = nil, recents: [String] = []) {
        state = PaletteState(scope: scope)
        state.recents = recents
        super.init()
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.onResignKey = { [weak self] in self?.close() }
        panel.onNewBranch = { [weak self] in self?.newBranch() }
        panel.contentView = makeContent()
        scopeBar.onSelect = { [weak self] scope in
            self?.state.setScope(scope)
            self?.render()
        }
    }

    private func makeContent() -> NSView {
        let background = NSVisualEffectView()
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        field.delegate = self
        let search = NSImageView()
        search.setSymbol("magnifyingglass", size: 15, color: Theme.secondaryText)
        let header = Style.stack([search, field], spacing: 10)
        let list = makeList()
        let hints = Style.label(
            String(localized: "↩ Open    ↑↓ Move    ⇥ Scope    ⌘N New branch    ⎋ Close"), size: 11,
            color: Theme.secondaryText)
        let stack = Style.stack(
            [header, teleportSlot, scopeBar, Deck.separator(), list, Deck.separator(), hints], vertical: true,
            spacing: 8)
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 10, right: 16)
        for view in [header, teleportSlot, scopeBar, list] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        list.setContentHuggingPriority(.defaultLow, for: .vertical)
        Style.fill(stack, in: background)
        return background
    }

    /// The results, and "No results" in their place when nothing is found.
    private func makeList() -> NSView {
        let list = NSView()
        let scroll = Style.scroll(makeTable())
        scroll.drawsBackground = false
        Style.fill(scroll, in: list)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        list.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: list.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: list.topAnchor, constant: Self.emptyLabelTop),
        ])
        return list
    }

    private func makeTable() -> NSTableView {
        let column = NSTableColumn(identifier: .init("item"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.headerView = nil
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(chooseClicked)
        table.setAccessibilityIdentifier("palette.list")
        return table
    }

    /// Computes the palette's frame over `parentFrame`, clamped to the best visible display.
    static func frame(over parentFrame: NSRect, screens: [NSRect], preferred: NSRect?) -> NSRect {
        let origin = NSPoint(
            x: parentFrame.midX - Self.size.width / 2,
            y: parentFrame.maxY - Self.size.height - min(120, parentFrame.height / 6))
        return WindowFrameClamp.clamped(
            NSRect(origin: origin, size: Self.size), screens: screens, preferred: preferred)
    }

    /// Shows the palette over the top of `parent`, clamped to the visible screen area, with the search focused.
    func show(over parent: NSWindow) {
        let target = Self.frame(
            over: parent.frame, screens: WindowFrameClamp.screenVisibleFrames(),
            preferred: parent.screen?.visibleFrame ?? NSScreen.main?.visibleFrame)
        panel.setFrame(target, display: false)
        WindowFrameClamp.track(panel)
        parent.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    func setTeleportBanner(_ view: NSView) {
        for subview in teleportSlot.arrangedSubviews {
            teleportSlot.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
        teleportSlot.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: teleportSlot.widthAnchor).isActive = true
    }

    func close() {
        panel.onResignKey = nil
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        onClose?()
    }

    /// The items, keeping what is typed and the selected item (dates and provider answers arrive after the first
    /// showing).
    func update(_ items: [PaletteItem]) {
        state.update(items)
        render()
    }

    private func render() {
        field.placeholderString =
            state.scope == .branch
            ? String(localized: "Switch to branch…") : String(localized: "Search commands, branches, pull requests…")
        scopeBar.show(state.scopes, selected: state.scope)
        table.reloadData()
        table.enclosingScrollView?.isHidden = state.rows.isEmpty
        emptyLabel.isHidden = !state.rows.isEmpty
        showSelection()
    }

    private func showSelection() {
        guard let row = state.selection else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        // A selection on the first page keeps the list at its top: the headings and rows above it stay in view.
        panel.contentView?.layoutSubtreeIfNeeded()
        let page = table.enclosingScrollView?.contentSize.height ?? 0
        table.scrollRowToVisible(table.rect(ofRow: row).maxY <= page ? 0 : row)
    }

    /// Runs the result at `row`; one that cannot run now stays, with the system's refusal.
    func choose(_ row: Int) {
        guard state.rows.indices.contains(row), let item = state.rows[row].result?.item else { return }
        guard item.isEnabled else {
            onUnavailable?()
            return
        }
        close()
        onChoose?(item)
    }

    @objc private func chooseClicked() { choose(table.clickedRow) }

    /// ⌘N in the palette: a new branch instead, named after what is typed.
    func newBranch() {
        close()
        onNewBranch?(field.stringValue.trimmingCharacters(in: .whitespaces))
    }

    // MARK: Keys

    func controlTextDidChange(_: Notification) {
        state.setQuery(field.stringValue)
        onQueryChange?(field.stringValue)
        render()
    }

    func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(by: 1)
        case #selector(NSResponder.moveUp(_:)): move(by: -1)
        case #selector(NSResponder.insertTab(_:)): cycleScope(forward: true)
        case #selector(NSResponder.insertBacktab(_:)): cycleScope(forward: false)
        case #selector(NSResponder.insertNewline(_:)): if let row = state.selection { choose(row) }
        case #selector(NSResponder.cancelOperation(_:)): close()
        default: return false
        }
        return true
    }

    private func move(by step: Int) {
        state.move(by: step)
        showSelection()
    }

    private func cycleScope(forward: Bool) {
        state.cycleScope(forward: forward)
        render()
    }

    // MARK: Table

    func numberOfRows(in _: NSTableView) -> Int { state.rows.count }

    func tableView(_: NSTableView, heightOfRow row: Int) -> CGFloat {
        state.rows[row].result == nil ? Self.headerHeight : Self.rowHeight
    }

    func tableView(_: NSTableView, shouldSelectRow row: Int) -> Bool { state.rows[row].result != nil }

    func tableView(_: NSTableView, rowViewForRow _: Int) -> NSTableRowView? { PaletteRowView() }

    func tableView(_ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        switch state.rows[row] {
        case .header(let kind, let more):
            let cell: PaletteHeaderCell = Self.reuse("palette.header", in: tableView)
            cell.show(kind, more: more)
            return cell
        case .result(let result):
            let cell: PaletteCell = Self.reuse("palette.cell", in: tableView)
            cell.show(result)
            return cell
        }
    }

    private static func reuse<Cell: NSTableCellView>(_ name: String, in tableView: NSTableView) -> Cell {
        let id = NSUserInterfaceItemIdentifier(name)
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? Cell ?? Cell()
        cell.identifier = id
        return cell
    }
}
