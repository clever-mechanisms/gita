import AppKit
import GitaCore

/// Copy, context-menu, and editor-open actions for `DiffView`.
extension DiffView {
    func copySelectedLines() { copyLines(rows: table.selectedRowIndexes) }

    func copyLines(rows: IndexSet) {
        let docRows = documentRows(forTableRows: rows, stageableOnly: false)
        let text = DiffDocumentBuilder.cleanCodeText(lines: currentLines, rows: docRows, isBlob: isBlob)
        if !text.isEmpty { copyText(text) }
    }

    func copyAsPatch(rows: IndexSet) {
        let docRows = documentRows(forTableRows: rows, stageableOnly: false)
        let text = DiffDocumentBuilder.patchText(document: document, lines: currentLines, rows: docRows)
        if !text.isEmpty { copyText(text) }
    }

    @objc func doubleClickedRow() {
        let docRows = documentRows(forTableRows: IndexSet(integer: table.clickedRow), stageableOnly: false)
        guard let row = docRows.first, currentLines.indices.contains(row), currentLines[row].kind != "@" else {
            return
        }
        onOpenInEditor?(DiffDocumentBuilder.sourceLineNumber(for: currentLines[row]))
    }

    func contextMenu(for rows: IndexSet) -> NSMenu? {
        guard !rows.isEmpty else { return nil }
        let docRows = documentRows(forTableRows: rows, stageableOnly: false)
        let menu = NSMenu()
        addCopyItems(to: menu, tableRows: rows, docRows: docRows)
        addStageItems(to: menu, tableRows: rows)
        addNavigationItems(to: menu, docRows: docRows)
        return menu
    }

    private func addCopyItems(to menu: NSMenu, tableRows: IndexSet, docRows: IndexSet) {
        let copyLinesItem = MenuAction(String(localized: "Copy Lines")) { [weak self] in
            self?.copyLines(rows: tableRows)
        }
        copyLinesItem.isEnabled =
            !DiffDocumentBuilder.cleanCodeText(lines: currentLines, rows: docRows, isBlob: isBlob).isEmpty
        menu.addItem(copyLinesItem)

        let copyPatchItem = MenuAction(String(localized: "Copy as Patch")) { [weak self] in
            self?.copyAsPatch(rows: tableRows)
        }
        let patch = DiffDocumentBuilder.patchText(document: document, lines: currentLines, rows: docRows)
        copyPatchItem.isEnabled = !isBlob && !patch.isEmpty
        menu.addItem(copyPatchItem)
    }

    private func addStageItems(to menu: NSMenu, tableRows: IndexSet) {
        let stageable = documentRows(forTableRows: tableRows, stageableOnly: true)
        guard hunkActionState.showsActions, hunkActionState.isEnabled, document?.canApplyHunks == true,
            !stageable.isEmpty
        else { return }
        menu.addItem(.separator())
        let count = stageable.count
        let stageTitle = Self.lineStageTitle(count: count, isStaged: hunkActionState.isStaged)
        menu.addItem(MenuAction(stageTitle) { [weak self] in self?.onStageLines?(stageable) })
        if !hunkActionState.isStaged {
            let discardTitle =
                count == 1 ? String(localized: "Discard 1 line…") : String(localized: "Discard \(count) lines…")
            menu.addItem(MenuAction(discardTitle) { [weak self] in self?.onDiscardLines?(stageable) })
        }
    }

    private static func lineStageTitle(count: Int, isStaged: Bool) -> String {
        if isStaged {
            return count == 1 ? String(localized: "Unstage 1 line") : String(localized: "Unstage \(count) lines")
        }
        return count == 1 ? String(localized: "Stage 1 line") : String(localized: "Stage \(count) lines")
    }

    private func addNavigationItems(to menu: NSMenu, docRows: IndexSet) {
        menu.addItem(.separator())
        let lineNumbers = docRows.compactMap { row -> Int? in
            guard currentLines.indices.contains(row) else { return nil }
            return DiffDocumentBuilder.sourceLineNumber(for: currentLines[row])
        }
        let firstLine = lineNumbers.first
        let openItem = MenuAction(String(localized: "Open in Editor at Line")) { [weak self] in
            self?.onOpenInEditor?(firstLine)
        }
        openItem.isEnabled = shownPath != nil
        menu.addItem(openItem)

        guard let path = shownPath else { return }
        let lineRange: ClosedRange<Int>? =
            if let start = lineNumbers.min(), let end = lineNumbers.max() { start...end } else { nil }
        if let onShowLineHistory, let lineRange {
            let spec = LineRangeSpec(path: path, startLine: lineRange.lowerBound, endLine: lineRange.upperBound)
            menu.addItem(
                MenuAction(String(localized: "Line History…"), symbol: "doc.text.magnifyingglass") {
                    onShowLineHistory(spec)
                })
        }
        if let onCopyPermalink, canCopyPermalink?() ?? true {
            menu.addItem(
                MenuAction(String(localized: "Copy Permalink"), symbol: "link") {
                    onCopyPermalink(path, lineRange)
                })
        }
        if let onOpenInExternalDiff, !isBlob {
            menu.addItem(
                MenuAction(String(localized: "Open in External Diff Tool"), symbol: "arrow.left.arrow.right.square") {
                    onOpenInExternalDiff()
                })
        }
    }
}
