import AppKit
import GitaCore

/// Shared `NSTableView` data source, delegate, and click/keyboard dispatcher for `SidebarRepositoriesPane` and
/// `SidebarRepositoryPane`.
@MainActor
final class SidebarPaneList: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    typealias Row = RepositorySidebarView.Row

    struct Actions {
        var onOpenCheckout: ((URL, Bool) -> Void)?
        var onNavigate: ((SidebarSelection) -> Void)?
        var onReference: ((GitReference, Bool) -> Void)?
        var onStash: ((GitStash) -> Void)?
        var onFilter: ((GitReference, BranchFilters.Kind) -> Void)?
        var onToggleRepository: ((RepositorySidebarView.Repository, Bool) -> Void)?
        var onSetRepositoryExpanded: ((RepositorySidebarView.Repository, Bool) -> Void)?
        var onSetGroupExpanded: ((SidebarGroupID, Bool) -> Void)?
        var referenceMenu: ((GitReference) -> NSMenu?)?
        var remoteMenu: ((String?) -> NSMenu?)?
        var checkoutMenu: ((String, Bool) -> NSMenu?)?
        var repositoryMenu: ((RepositorySidebarView.Repository) -> NSMenu?)?
        var onDropBranch: ((String, GitReference, Int) -> Void)?
        var onDropCommits: (([String], GitReference) -> Void)?
    }

    let table = SidebarTable()
    let scroll = NSScrollView()
    var actions = Actions()
    var onClickRow: ((Int) -> Void)?
    var onDoubleClickRow: ((Int) -> Void)?
    var onActivateRow: ((Int, Bool) -> Void)?
    var onChangeGroupRow: ((Int, SidebarTable.GroupChange) -> Bool)?
    var onRowMenu: ((Int) -> NSMenu?)?
    var currentEventType: () -> NSEvent.EventType? = { NSApp.currentEvent?.type }
    var currentModifiers: () -> NSEvent.ModifierFlags = { [] }
    var typeSelectString: ((Row) -> String?)?

    private(set) var rows: [Row] = []
    private var updating = false

    func configure(accessibilityLabel: String, allowsTypeSelect: Bool, contentInsets: NSEdgeInsets) {
        table.addTableColumn(NSTableColumn(identifier: .init("sidebar")))
        table.headerView = nil
        table.intercellSpacing = .zero
        table.style = .plain
        table.backgroundColor = .clear
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.selectionHighlightStyle = .regular
        table.allowsTypeSelect = allowsTypeSelect
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clickedRow)
        table.doubleAction = #selector(doubleClick)
        table.rowMenu = { [weak self] row in
            guard let self else { return nil }
            return self.onRowMenu?(row) ?? self.performMenu(row)
        }
        table.onReturn = { [weak self] in
            guard let self, self.table.selectedRow >= 0 else { return }
            let row = self.table.selectedRow
            if let onActivateRow = self.onActivateRow {
                onActivateRow(row, false)
            } else {
                self.performActivate(row, fromKeyboard: false)
            }
        }
        table.onExpand = { [weak self] change in
            guard let self else { return false }
            let row = self.table.selectedRow
            return self.onChangeGroupRow?(row, change) ?? self.performChangeGroup(row, change)
        }
        table.onChevronClick = { [weak self] row in self?.performChevron(row) }
        table.setAccessibilityLabel(accessibilityLabel)
        table.registerForDraggedTypes([GitaDragReference.pasteboardType])
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.contentInsets = contentInsets
    }

    var scrollOffset: CGFloat {
        get { scroll.contentView.bounds.origin.y }
        set {
            table.layoutSubtreeIfNeeded()
            let maximum = max(
                -scroll.contentInsets.top,
                table.frame.height - scroll.contentView.bounds.height + scroll.contentInsets.bottom)
            scroll.contentView.scroll(
                to: NSPoint(
                    x: scroll.contentView.bounds.origin.x, y: min(max(newValue, -scroll.contentInsets.top), maximum)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    func applyRows(_ next: [Row], highlight: Int? = nil) {
        let clip = scroll.contentView
        let origin = clip.bounds.origin
        updating = true
        defer { updating = false }
        let previous = rows
        let selectedRow = previous.indices.contains(table.selectedRow) ? previous[table.selectedRow] : nil
        let focusedGroup = selectedRow?.group?.id
        let focusedRepository: URL? =
            if case .repository(let repo, _) = selectedRow { repo.root } else { nil }
        rows = next
        reload(from: previous)
        if let focusedGroup, let row = rows.firstIndex(where: { $0.group?.id == focusedGroup }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else if let focusedRepository,
            let row = rows.firstIndex(where: {
                if case .repository(let candidate, _) = $0 { candidate.root == focusedRepository } else { false }
            })
        {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else if let selected = highlight ?? rows.firstIndex(where: \.isSelected) {
            table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
    }

    private func reload(from previous: [Row]) {
        guard previous.count == rows.count, zip(previous, rows).allSatisfy({ $0.kind == $1.kind }) else {
            table.reloadData()
            return
        }
        let changed = IndexSet(rows.indices.filter { previous[$0] != rows[$0] })
        if !changed.isEmpty { table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0)) }
        let resized = IndexSet(changed.filter { previous[$0].height != rows[$0].height })
        guard !resized.isEmpty else { return }
        NSAnimationContext.runAnimationGroup {
            $0.duration = 0
            table.noteHeightOfRows(withIndexesChanged: resized)
        }
    }

    // MARK: NSTableViewDataSource & NSTableViewDelegate

    func numberOfRows(in _: NSTableView) -> Int { rows.count }
    func tableView(_: NSTableView, heightOfRow row: Int) -> CGFloat { rows[row].height }

    func tableView(_: NSTableView, shouldSelectRow row: Int) -> Bool {
        rows[row].isSelectable || (rows[row].group != nil && currentEventType() == .keyDown)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow _: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("sidebar.row")
        return tableView.makeView(withIdentifier: id, owner: nil) as? DeckTableRowView
            ?? {
                let view = DeckTableRowView()
                view.identifier = id
                return view
            }()
    }

    func tableView(_ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("sidebar.cell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? SidebarCell ?? SidebarCell()
        cell.identifier = id
        cell.configure(rows[row])
        cell.onPress = rows[row].group.map { group in
            { [weak self] in
                guard let self, let index = self.rows.firstIndex(where: { $0.group?.id == group.id }) else { return }
                _ = self.onChangeGroupRow?(index, .toggle) ?? self.performChangeGroup(index, .toggle)
            }
        }
        if case .reference(let reference) = rows[row] {
            cell.onFilter = { [weak self] kind in self?.actions.onFilter?(reference.reference, kind) }
        } else {
            cell.onFilter = nil
        }
        return cell
    }

    func tableViewSelectionDidChange(_: Notification) {
        guard !updating, table.selectedRow >= 0, currentEventType() == .keyDown else { return }
        let row = table.selectedRow
        if let onActivateRow {
            onActivateRow(row, true)
        } else {
            performActivate(row, fromKeyboard: true)
        }
    }

    func tableView(_: NSTableView, typeSelectStringFor _: NSTableColumn?, row: Int) -> String? {
        guard rows.indices.contains(row) else { return nil }
        return typeSelectString?(rows[row])
    }

    var repositoryRoot: () -> String? = { nil }

    func tableView(_: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard let root = repositoryRoot(), rows.indices.contains(row), case .reference(let refRow) = rows[row],
            refRow.reference.kind == .branch || refRow.reference.kind == .remote
        else { return nil }
        return GitaDragReference.branch(
            fullName: refRow.reference.fullName, name: refRow.reference.name,
            isRemote: refRow.reference.kind == .remote
        ).pasteboardItem(repositoryRoot: root)
    }

    func tableView(
        _ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
        proposedDropOperation _: NSTableView.DropOperation
    ) -> NSDragOperation {
        let operation = dropOperation(for: info.draggingPasteboard.pasteboardItems ?? [], row: row)
        if !operation.isEmpty { tableView.setDropRow(row, dropOperation: .on) }
        return operation
    }

    func tableView(
        _: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation _: NSTableView.DropOperation
    ) -> Bool {
        acceptDrop(from: info.draggingPasteboard.pasteboardItems ?? [], row: row)
    }

    func dropOperation(for items: [NSPasteboardItem], row: Int) -> NSDragOperation {
        guard rows.indices.contains(row), case .reference(let target) = rows[row],
            target.reference.kind == .branch
        else { return [] }
        if let branch = GitaDragReference.firstBranch(from: items, repositoryRoot: repositoryRoot()),
            branch.fullName != target.reference.fullName
        {
            return .move
        }
        if !GitaDragReference.commitIDs(from: items, repositoryRoot: repositoryRoot()).isEmpty { return .copy }
        return []
    }

    @discardableResult
    func acceptDrop(from items: [NSPasteboardItem], row: Int) -> Bool {
        guard rows.indices.contains(row), case .reference(let target) = rows[row],
            target.reference.kind == .branch
        else { return false }
        if let branch = GitaDragReference.firstBranch(from: items, repositoryRoot: repositoryRoot()),
            branch.fullName != target.reference.fullName
        {
            actions.onDropBranch?(branch.fullName, target.reference, row)
            return true
        }
        let commitIDs = GitaDragReference.commitIDs(from: items, repositoryRoot: repositoryRoot())
        if !commitIDs.isEmpty {
            actions.onDropCommits?(commitIDs, target.reference)
            return true
        }
        return false
    }

    // MARK: Actions

    @objc private func clickedRow() {
        let row = table.clickedRow
        if let onClickRow { onClickRow(row) } else { performClick(row) }
    }

    @objc private func doubleClick() {
        let row = table.clickedRow
        if let onDoubleClickRow { onDoubleClickRow(row) } else { performSecondClick(row) }
    }

    func performClick(_ row: Int, modifiers: NSEvent.ModifierFlags? = nil) {
        let resolved = modifiers ?? (table.lastClickModifiers ?? currentModifiers())
        performActivate(row, fromKeyboard: false, modifiers: resolved)
    }

    func performSecondClick(_ row: Int, modifiers: NSEvent.ModifierFlags? = nil) {
        performClick(row, modifiers: modifiers)
    }

    func performChevron(_ row: Int) {
        guard rows.indices.contains(row) else { return }
        if case .repository(let repository, let expanded) = rows[row] {
            actions.onToggleRepository?(repository, expanded)
            return
        }
        _ = onChangeGroupRow?(row, .toggle) ?? performChangeGroup(row, .toggle)
    }

    func performActivate(_ row: Int, fromKeyboard: Bool, modifiers: NSEvent.ModifierFlags = []) {
        guard rows.indices.contains(row) else { return }
        let newTab = modifiers.contains(.command)
        switch rows[row] {
        case .repository(let repository, let expanded):
            guard !fromKeyboard else { return }
            if !expanded { actions.onSetRepositoryExpanded?(repository, true) }
            actions.onOpenCheckout?(repository.primaryCheckoutURL, newTab)
        case .checkout(let checkout, _, _):
            guard !fromKeyboard else { return }
            actions.onOpenCheckout?(URL(fileURLWithPath: checkout.path, isDirectory: true), newTab)
        case .nav(let nav):
            activateNav(nav, row: row, fromKeyboard: fromKeyboard)
        case .reference(let reference):
            actions.onReference?(reference.reference, newTab)
        case .stash(let stash, _):
            actions.onStash?(stash)
        case .remote, .folder:
            toggleGroup(row, fromKeyboard: fromKeyboard)
        case .header, .subheader, .divider, .empty:
            break
        }
    }

    private func activateNav(_ nav: RepositorySidebarView.Nav, row: Int, fromKeyboard: Bool) {
        if case .page(let page) = nav.target { actions.onNavigate?(page) }
        if rows[row].group != nil { toggleGroup(row, fromKeyboard: fromKeyboard) }
    }

    private func toggleGroup(_ row: Int, fromKeyboard: Bool) {
        guard !fromKeyboard else { return }
        _ = onChangeGroupRow?(row, .toggle) ?? performChangeGroup(row, .toggle)
    }

    @discardableResult
    func performChangeGroup(_ row: Int, _ change: SidebarTable.GroupChange) -> Bool {
        guard rows.indices.contains(row) else { return false }
        if case .repository(let repository, let expanded) = rows[row] {
            let next = Self.targetExpansion(change, current: expanded)
            if next != expanded { actions.onSetRepositoryExpanded?(repository, next) }
            return true
        }
        guard let group = rows[row].group else { return false }
        let next = Self.targetExpansion(change, current: group.expanded)
        if next != group.expanded { actions.onSetGroupExpanded?(group.id, next) }
        return true
    }

    private static func targetExpansion(_ change: SidebarTable.GroupChange, current: Bool) -> Bool {
        switch change {
        case .open: true
        case .close: false
        case .toggle: !current
        }
    }

    func performMenu(_ row: Int) -> NSMenu? {
        guard rows.indices.contains(row) else { return nil }
        switch rows[row] {
        case .reference(let reference): return actions.referenceMenu?(reference.reference)
        case .checkout(let checkout, _, _): return actions.checkoutMenu?(checkout.path, checkout.isMain)
        case .repository(let repository, _):
            return actions.repositoryMenu?(repository) ?? actions.checkoutMenu?(repository.root.path, true)
        case .remote(let name, _, _, _): return actions.remoteMenu?(name)
        case .nav(let nav) where nav.target == .group(.remotes): return actions.remoteMenu?(nil)
        default: return nil
        }
    }
}
