import AppKit
import GitaCore

/// Floating action bar shown when stageable/discardable diff lines are selected.
@MainActor
final class DiffSelectionBar: NSView {
    let stageButton = PartsButton([], background: .accent, accessibility: String(localized: "Stage Selected Lines"))
    let discardButton = PartsButton([], background: .quiet, accessibility: String(localized: "Discard Selected Lines…"))

    var onStage: (() -> Void)?
    var onDiscard: (() -> Void)?

    private let stack: NSStackView

    override init(frame frameRect: NSRect) {
        stack = Style.stack([stageButton, discardButton], spacing: 8)
        stack.detachesHiddenViews = true
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        setAccessibilityElement(false)

        stageButton.fixedHeight = 24
        stageButton.cornerRadius = 5
        stageButton.horizontalPadding = 10
        stageButton.setAccessibilityIdentifier("diff.stageLines")
        stageButton.onClick = { [weak self] in self?.onStage?() }

        discardButton.fixedHeight = 24
        discardButton.cornerRadius = 5
        discardButton.horizontalPadding = 10
        discardButton.setAccessibilityIdentifier("diff.discardLines")
        discardButton.onClick = { [weak self] in self?.onDiscard?() }

        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        Style.fill(stack, in: self)
        isHidden = true
        refreshColors()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("DiffSelectionBar is built in code") }

    func configure(count: Int, isStaged: Bool) {
        guard count > 0 else {
            isHidden = true
            return
        }
        isHidden = false
        let stageTitle: String
        if isStaged {
            stageTitle = count == 1 ? String(localized: "Unstage 1 line") : String(localized: "Unstage \(count) lines")
        } else {
            stageTitle = count == 1 ? String(localized: "Stage 1 line") : String(localized: "Stage \(count) lines")
        }
        stageButton.parts = [
            .symbol(isStaged ? "minus" : "plus", color: Deck.onAccent, size: 10),
            .text(stageTitle, font: Theme.captionEmphasis, color: Deck.onAccent),
        ]
        stageButton.setAccessibilityLabel(stageTitle)
        stageButton.toolTip = stageTitle

        let discardTitle =
            count == 1 ? String(localized: "Discard 1 line…") : String(localized: "Discard \(count) lines…")
        discardButton.parts = [
            .symbol("arrow.uturn.backward", color: Theme.failure, size: 10),
            .text(discardTitle, font: Theme.captionEmphasis, color: Theme.failure),
        ]
        discardButton.setAccessibilityLabel(discardTitle)
        discardButton.toolTip = discardTitle
        discardButton.isHidden = isStaged
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    private func refreshColors() {
        layer?.backgroundColor = Theme.toolbar.cgColor
        layer?.borderColor = Theme.separator.cgColor
    }
}

/// Line-level selection, gutter toggle/range selection, and floating bar wiring for `DiffView`.
extension DiffView {
    var selectedStageableDocumentRows: IndexSet {
        guard hunkActionState.showsActions, hunkActionState.isEnabled, document?.canApplyHunks == true else {
            return IndexSet()
        }
        return documentRows(forTableRows: table.selectedRowIndexes, stageableOnly: true)
    }

    func documentRows(forTableRows tableRows: IndexSet, stageableOnly: Bool) -> IndexSet {
        activeLayout == .split
            ? splitDocumentRows(forTableRows: tableRows, stageableOnly: stageableOnly)
            : unifiedDocumentRows(forTableRows: tableRows, stageableOnly: stageableOnly)
    }

    private func splitDocumentRows(forTableRows tableRows: IndexSet, stageableOnly: Bool) -> IndexSet {
        var result = IndexSet()
        for tableRow in tableRows where splitRows.indices.contains(tableRow) {
            let split = splitRows[tableRow]
            if stageableOnly {
                split.stageableDocumentRows.forEach { result.insert($0) }
            } else {
                if let left = split.leftRowIndex { result.insert(left) }
                if let right = split.rightRowIndex { result.insert(right) }
            }
        }
        return result
    }

    private func unifiedDocumentRows(forTableRows tableRows: IndexSet, stageableOnly: Bool) -> IndexSet {
        var result = IndexSet()
        for row in tableRows where currentLines.indices.contains(row) {
            let line = currentLines[row]
            if !stageableOnly || (line.hunkIndex != nil && (line.kind == "+" || line.kind == "-")) {
                result.insert(row)
            }
        }
        return result
    }

    func configureSelectionBar() {
        selectionBar.onStage = { [weak self] in
            guard let self else { return }
            let rows = self.selectedStageableDocumentRows
            if !rows.isEmpty { self.onStageLines?(rows) }
        }
        selectionBar.onDiscard = { [weak self] in
            guard let self else { return }
            let rows = self.selectedStageableDocumentRows
            if !rows.isEmpty { self.onDiscardLines?(rows) }
        }
    }

    func updateSelectionBar() {
        let count = selectedStageableDocumentRows.count
        selectionBar.configure(count: count, isStaged: hunkActionState.isStaged)
    }

    func isGutterHit(pointX: CGFloat) -> Bool {
        if activeLayout == .split {
            let halfWidth = floor(table.bounds.width / 2)
            let splitGutter: CGFloat = 46
            return pointX < splitGutter || (pointX >= halfWidth + 1 && pointX < halfWidth + 1 + splitGutter)
        }
        return pointX < DiffCell.gutterWidth
    }

    func handleGutterClick(row: Int, pointX: CGFloat = 0, flags: NSEvent.ModifierFlags) -> Bool {
        guard isGutterHit(pointX: pointX),
            hunkActionState.showsActions, hunkActionState.isEnabled, document?.canApplyHunks == true,
            !documentRows(forTableRows: IndexSet(integer: row), stageableOnly: true).isEmpty
        else { return false }

        var next = table.selectedRowIndexes
        if flags.contains(.shift), let anchor = lastGutterAnchorRow ?? next.first {
            let low = min(anchor, row)
            let high = max(anchor, row)
            for candidate in low...high
            where !documentRows(forTableRows: IndexSet(integer: candidate), stageableOnly: true).isEmpty {
                next.insert(candidate)
            }
        } else {
            if next.contains(row) {
                next.remove(row)
            } else {
                next.insert(row)
            }
            lastGutterAnchorRow = row
        }
        table.selectRowIndexes(next, byExtendingSelection: false)
        window?.makeFirstResponder(table)
        return true
    }
}
