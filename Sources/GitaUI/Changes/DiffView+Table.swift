import AppKit
import GitaCore

/// Diff table supporting multi-row `⌘C`, gutter line selection, context menus, and scoped Find shortcuts.
@MainActor
final class DiffTableView: NSTableView {
    var onCopySelection: (() -> Void)?
    var onMenuForRows: ((IndexSet) -> NSMenu?)?
    var onKeyEquivalent: ((NSEvent) -> Bool)?
    var onGutterClick: ((Int, CGFloat, NSEvent.ModifierFlags) -> Bool)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let clicked = row(at: point)
        if clicked >= 0, onGutterClick?(clicked, point.x, event.modifierFlags) == true {
            return
        }
        super.mouseDown(with: event)
    }

    @objc func copy(_: Any?) {
        onCopySelection?()
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) {
            return !selectedRowIndexes.isEmpty
        }
        return super.validateUserInterfaceItem(item)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown,
            event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command],
            event.charactersIgnoringModifiers?.lowercased() == "c",
            !selectedRowIndexes.isEmpty
        {
            copy(nil)
            return true
        }
        if onKeyEquivalent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clicked = row(at: point)
        guard clicked >= 0 else { return nil }
        let rows = selectedRowIndexes.contains(clicked) ? selectedRowIndexes : IndexSet(integer: clicked)
        if !selectedRowIndexes.contains(clicked) {
            selectRowIndexes(rows, byExtendingSelection: false)
        }
        return onMenuForRows?(rows)
    }
}

/// Table data source, delegate, and cell configuration for `DiffView`.
extension DiffView {
    var displayedRowCount: Int { activeLayout == .split ? splitRows.count : currentLines.count }

    var canExpandContext: Bool {
        !isBlob && !currentLines.isEmpty && document?.hunks.isEmpty == false && diffOptions.canExpandContext
            && onExpandContext != nil
    }

    func numberOfRows(in _: NSTableView) -> Int {
        displayedRowCount + (canExpandContext ? 1 : 0)
    }

    func tableView(_: NSTableView, shouldSelectRow row: Int) -> Bool {
        !(canExpandContext && row == displayedRowCount)
    }

    func tableViewSelectionDidChange(_: Notification) {
        refreshDiffCells()
        updateSelectionBar()
    }

    func tableView(_: NSTableView, heightOfRow row: Int) -> CGFloat {
        if canExpandContext && row == displayedRowCount {
            return DiffContextExpandBar.height
        }
        if activeLayout == .split {
            guard splitRows.indices.contains(row) else { return lineRowHeight }
            return splitRows[row].isHunkHeader ? max(DiffHunkBar.height, lineRowHeight) : lineRowHeight
        }
        guard currentLines.indices.contains(row) else { return lineRowHeight }
        if currentLines[row].kind == "@", currentLines[row].hunkIndex != nil {
            return max(DiffHunkBar.height, lineRowHeight)
        }
        return lineRowHeight
    }

    func tableView(_ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        if canExpandContext && row == displayedRowCount {
            let expand =
                tableView.makeView(withIdentifier: Self.expandBarID, owner: nil) as? DiffContextExpandBar
                ?? DiffContextExpandBar()
            expand.identifier = Self.expandBarID
            expand.configure(context: diffOptions.context)
            expand.onExpand = { [weak self] in self?.onExpandContext?() }
            return expand
        }
        if activeLayout == .split {
            return splitViewForRow(tableView, row: row)
        }
        guard currentLines.indices.contains(row) else { return nil }
        if currentLines[row].kind == "@", currentLines[row].hunkIndex != nil {
            let bar = tableView.makeView(withIdentifier: Self.hunkBarID, owner: nil) as? DiffHunkBar ?? DiffHunkBar()
            bar.identifier = Self.hunkBarID
            configure(bar, for: row)
            return bar
        }
        let cell = tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? DiffCell ?? DiffCell()
        cell.identifier = Self.cellID
        configure(cell, for: row, selectedDocRows: selectedStageableDocumentRows)
        return cell
    }

    func configure(_ bar: DiffHunkBar, for row: Int) {
        let line = currentLines[row]
        configureHunkBar(bar, line: line)
    }

    func configureHunkBar(_ bar: DiffHunkBar, line: DiffLine) {
        guard let hunkIndex = line.hunkIndex else { return }
        let canAct = hunkActionState.showsActions && document?.canApplyHunks == true
        bar.configure(
            DiffHunkBar.Configuration(
                header: line.text, hunkIndex: hunkIndex, totalHunks: document?.hunks.count ?? 1,
                showsActions: canAct, isStaged: hunkActionState.isStaged, isEnabled: hunkActionState.isEnabled,
                fontSize: fontSize))
        bar.setReviewAction(reviewAction?(hunkIndex))
        bar.onStage = { [weak self] in self?.onStageHunk?(hunkIndex) }
        bar.onDiscard = { [weak self] in self?.onDiscardHunk?(hunkIndex) }
        bar.trailingInset = currentTrailingInset
    }

    func configure(_ cell: DiffCell, for row: Int, selectedDocRows: IndexSet) {
        let line = currentLines[row]
        cell.fontSize = fontSize
        cell.tabWidth = tabWidth
        cell.isBlobLine = isBlob
        cell.line = line
        cell.wordHighlights = wordHighlights.indices.contains(row) ? wordHighlights[row] : []
        cell.syntaxTokens = syntaxTokens.indices.contains(row) ? syntaxTokens[row] : []
        cell.isStageSelectionMarked = selectedDocRows.contains(row)
        let highlight = findHighlight(for: row)
        cell.findMatches = highlight.ranges
        cell.activeFindMatchIndex = highlight.activeIndex
        cell.customActions = customActions(for: line)
    }

    func customActions(for line: DiffLine) -> [NSAccessibilityCustomAction] {
        guard let hunkIndex = line.hunkIndex, hunkActionState.showsActions, hunkActionState.isEnabled,
            document?.canApplyHunks == true
        else { return [] }
        let stageTitle = hunkActionState.isStaged ? String(localized: "Unstage Hunk") : String(localized: "Stage Hunk")
        var actions = [
            NSAccessibilityCustomAction(name: stageTitle) { [weak self] in
                self?.onStageHunk?(hunkIndex)
                return true
            }
        ]
        if !hunkActionState.isStaged {
            actions.append(
                NSAccessibilityCustomAction(name: String(localized: "Discard Hunk…")) { [weak self] in
                    self?.onDiscardHunk?(hunkIndex)
                    return true
                })
        }
        return actions
    }

    func refreshDiffCells() {
        let selectedDocRows = selectedStageableDocumentRows
        table.enumerateAvailableRowViews { rowView, row in
            if row == displayedRowCount && canExpandContext {
                if let expand = rowView.view(atColumn: 0) as? DiffContextExpandBar {
                    expand.configure(context: diffOptions.context)
                }
                return
            }
            if activeLayout == .split, splitRows.indices.contains(row) {
                configureSplitView(rowView: rowView, row: row, selectedDocRows: selectedDocRows)
                return
            }
            guard currentLines.indices.contains(row) else { return }
            if let cell = rowView.view(atColumn: 0) as? DiffCell {
                configure(cell, for: row, selectedDocRows: selectedDocRows)
            } else if let bar = rowView.view(atColumn: 0) as? DiffHunkBar {
                configure(bar, for: row)
            }
        }
    }

    func setHiddenReviewHunks(_ indices: Set<Int>) {
        guard indices != hiddenReviewHunks else { return }
        hiddenReviewHunks = indices
        applyReviewFilter()
    }

    func applyReviewFilter() {
        var hidden = IndexSet()
        if !hiddenReviewHunks.isEmpty {
            for row in 0..<displayedRowCount {
                let index =
                    activeLayout == .split
                    ? (splitRows[row].left ?? splitRows[row].right)?.hunkIndex : currentLines[row].hunkIndex
                if let index, hiddenReviewHunks.contains(index) { hidden.insert(row) }
            }
        }
        let previouslyHidden = table.hiddenRowIndexes
        guard hidden != previouslyHidden else { return }
        table.unhideRows(at: previouslyHidden.subtracting(hidden), withAnimation: [])
        let newlyHidden = hidden.subtracting(previouslyHidden)
        table.selectedRowIndexes.intersection(newlyHidden).forEach { table.deselectRow($0) }
        table.hideRows(at: newlyHidden, withAnimation: [])
    }

    func reconfigureVisibleRows() { refreshDiffCells() }
}
