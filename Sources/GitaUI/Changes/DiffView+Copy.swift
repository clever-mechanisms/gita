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
        let copyLinesItem = MenuAction(String(localized: "Copy Lines")) { [weak self] in self?.copyLines(rows: rows) }
        copyLinesItem.isEnabled = !DiffDocumentBuilder.cleanCodeText(
            lines: currentLines, rows: docRows, isBlob: isBlob
        ).isEmpty
        menu.addItem(copyLinesItem)

        let copyPatchItem = MenuAction(String(localized: "Copy as Patch")) { [weak self] in
            self?.copyAsPatch(rows: rows)
        }
        let patch = DiffDocumentBuilder.patchText(document: document, lines: currentLines, rows: docRows)
        copyPatchItem.isEnabled = !isBlob && !patch.isEmpty
        menu.addItem(copyPatchItem)

        let stageable = documentRows(forTableRows: rows, stageableOnly: true)
        if hunkActionState.showsActions, hunkActionState.isEnabled, document?.canApplyHunks == true, !stageable.isEmpty
        {
            menu.addItem(.separator())
            let count = stageable.count
            let stageTitle =
                hunkActionState.isStaged
                ? (count == 1 ? String(localized: "Unstage 1 line") : String(localized: "Unstage \(count) lines"))
                : (count == 1 ? String(localized: "Stage 1 line") : String(localized: "Stage \(count) lines"))
            menu.addItem(MenuAction(stageTitle) { [weak self] in self?.onStageLines?(stageable) })
            if !hunkActionState.isStaged {
                let discardTitle =
                    count == 1 ? String(localized: "Discard 1 line…") : String(localized: "Discard \(count) lines…")
                menu.addItem(MenuAction(discardTitle) { [weak self] in self?.onDiscardLines?(stageable) })
            }
        }

        menu.addItem(.separator())
        let firstLine = docRows.first.flatMap {
            currentLines.indices.contains($0) ? DiffDocumentBuilder.sourceLineNumber(for: currentLines[$0]) : nil
        }
        let openItem = MenuAction(String(localized: "Open in Editor at Line")) { [weak self] in
            self?.onOpenInEditor?(firstLine)
        }
        openItem.isEnabled = shownPath != nil
        menu.addItem(openItem)

        if let path = shownPath {
            let lineNumbers = docRows.compactMap { row -> Int? in
                guard currentLines.indices.contains(row) else { return nil }
                return DiffDocumentBuilder.sourceLineNumber(for: currentLines[row])
            }
            let lineRange: ClosedRange<Int>? =
                if let start = lineNumbers.min(), let end = lineNumbers.max() { start...end } else { nil }
            if let onShowLineHistory, let lineRange {
                let spec = LineRangeSpec(path: path, startLine: lineRange.lowerBound, endLine: lineRange.upperBound)
                menu.addItem(
                    MenuAction(String(localized: "Line History…"), symbol: "doc.text.magnifyingglass") {
                        onShowLineHistory(spec)
                    })
            }
            if let onCopyPermalink {
                menu.addItem(
                    MenuAction(String(localized: "Copy Permalink"), symbol: "link") {
                        onCopyPermalink(path, lineRange)
                    })
            }
            if let onOpenInExternalDiff, !isBlob {
                menu.addItem(
                    MenuAction(String(localized: "Open in External Diff Tool"), symbol: "arrow.left.arrow.right.square")
                    {
                        onOpenInExternalDiff()
                    })
            }
        }
        return menu
    }
}
