import AppKit
import GitaCore

/// Lifecycle state of the Find bar in `DiffView`.
enum DiffFind {
    case closed
    case open(query: String, matches: [Int], current: Int)
    case searching(Task<Void, Never>)

    var isOpen: Bool {
        if case .closed = self { return false }
        return true
    }

    var matches: [Int] {
        if case .open(_, let matches, _) = self { return matches }
        return []
    }

    var counterText: String {
        switch self {
        case .closed: ""
        case .searching: String(localized: "Searching…")
        case .open(let query, let matches, let current):
            if query.isEmpty {
                ""
            } else if matches.isEmpty {
                String(localized: "No matches")
            } else {
                String(localized: "\(current + 1) of \(matches.count)")
            }
        }
    }
}

/// Pure case-insensitive search over parsed `DiffLine` rows, producing row indices and UTF-16 ranges per row.
enum DiffFindMatcher {
    struct Result: Sendable, Equatable {
        var rows: [Int]
        var rangesByRow: [Int: [Range<Int>]]
    }

    static func match(query: String, in lines: [DiffLine], isBlob: Bool) -> Result {
        guard !query.isEmpty else { return Result(rows: [], rangesByRow: [:]) }
        var rows: [Int] = []
        var rangesByRow: [Int: [Range<Int>]] = [:]
        for (rowIndex, line) in lines.enumerated() {
            let stripPrefix =
                !isBlob && (line.kind == "+" || line.kind == "-" || (line.kind == " " && line.hunkIndex != nil))
            let offset = stripPrefix ? 1 : 0
            let haystack = stripPrefix ? String(line.text.dropFirst()) : line.text
            let found = utf16Matches(of: query, in: haystack, offset: offset)
            if !found.isEmpty {
                rangesByRow[rowIndex] = found
                rows.append(contentsOf: repeatElement(rowIndex, count: found.count))
            }
        }
        return Result(rows: rows, rangesByRow: rangesByRow)
    }

    static func utf16Matches(of query: String, in text: String, offset: Int = 0) -> [Range<Int>] {
        guard !query.isEmpty, !text.isEmpty else { return [] }
        var ranges: [Range<Int>] = []
        var searchStart = text.startIndex
        let utf16 = text.utf16
        while searchStart < text.endIndex,
            let range = text.range(of: query, options: .caseInsensitive, range: searchStart..<text.endIndex)
        {
            guard !range.isEmpty else { break }
            let lower = utf16.distance(from: text.startIndex, to: range.lowerBound) + offset
            let upper = utf16.distance(from: text.startIndex, to: range.upperBound) + offset
            ranges.append(lower..<upper)
            searchStart = range.upperBound
        }
        return ranges
    }
}

/// Slim inline Find bar shown above `DiffView`.
@MainActor
final class DiffFindBar: NSView, NSSearchFieldDelegate {
    static let height: CGFloat = 32

    let field = NSSearchField()
    let countLabel = Deck.label("", font: Theme.caption, color: Theme.secondaryText)
    let previousButton = PartsButton(
        [.symbol("chevron.up", color: Theme.text, size: 10)], background: .hover,
        accessibility: String(localized: "Previous Match"))
    let nextButton = PartsButton(
        [.symbol("chevron.down", color: Theme.text, size: 10)], background: .hover,
        accessibility: String(localized: "Next Match"))
    let closeButton = PartsButton(
        [.symbol("xmark", color: Theme.secondaryText, size: 10)], background: .hover,
        accessibility: String(localized: "Close Find"))

    var onQueryChange: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onClose: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        field.placeholderString = String(localized: "Find in Diff")
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.controlSize = .small
        field.font = Theme.body
        field.delegate = self
        field.setAccessibilityIdentifier("diff.findField")
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        countLabel.setAccessibilityIdentifier("diff.findCount")
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        for button in [previousButton, nextButton, closeButton] {
            button.fixedHeight = 20
            button.horizontalPadding = 5
            button.cornerRadius = 4
        }
        previousButton.toolTip = String(localized: "Previous Match  ⇧⌘G")
        nextButton.toolTip = String(localized: "Next Match  ⌘G")
        closeButton.toolTip = String(localized: "Close Find  Esc")
        previousButton.onClick = { [weak self] in self?.onPrevious?() }
        nextButton.onClick = { [weak self] in self?.onNext?() }
        closeButton.onClick = { [weak self] in self?.onClose?() }

        let stack = Style.stack([field, countLabel, previousButton, nextButton, closeButton], spacing: 6)
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        Style.fill(stack, in: self)
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("DiffFindBar is built in code") }

    func apply(_ state: DiffFind) {
        countLabel.stringValue = state.counterText
        let hasMatches = !state.matches.isEmpty
        previousButton.isEnabled = hasMatches
        nextButton.isEnabled = hasMatches
    }

    func focusField() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func controlTextDidChange(_: Notification) {
        onQueryChange?(field.stringValue)
    }

    func control(_: NSControl, textView _: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onClose?()
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                onPrevious?()
            } else {
                onNext?()
            }
            return true
        }
        return false
    }

    override func draw(_: NSRect) {
        Theme.inset.setFill()
        bounds.fill()
        Theme.separator.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

/// Find bar lifecycle, off-main-thread matching, navigation, and match highlight lookup for `DiffView`.
extension DiffView {
    func openFind() {
        if !findState.isOpen {
            findState = .open(query: findBar.field.stringValue, matches: [], current: 0)
            applyFindVisibility()
            if !findBar.field.stringValue.isEmpty {
                updateFindQuery(findBar.field.stringValue)
            }
        }
        findBar.focusField()
    }

    func closeFind() {
        if case .searching(let task) = findState { task.cancel() }
        findGeneration += 1
        findState = .closed
        findMatchRanges = [:]
        applyFindVisibility()
        refreshDiffCells()
        window?.makeFirstResponder(table)
    }

    func findNext() {
        stepFindMatch(delta: 1)
    }

    func findPrevious() {
        stepFindMatch(delta: -1)
    }

    func updateFindQuery(_ query: String) {
        if case .searching(let task) = findState { task.cancel() }
        findGeneration += 1
        let token = findGeneration
        lastFindQuery = query
        guard !query.isEmpty else {
            findState = .open(query: "", matches: [], current: 0)
            findMatchRanges = [:]
            findBar.apply(findState)
            refreshDiffCells()
            return
        }
        let snapshotLines = currentLines
        let blob = isBlob
        let work = Task.detached(priority: .userInitiated) {
            DiffFindMatcher.match(query: query, in: snapshotLines, isBlob: blob)
        }
        let task = Task { [weak self] in
            let result = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
            guard let self, !Task.isCancelled, self.findGeneration == token else { return }
            self.finishFind(query: query, result: result)
        }
        findState = .searching(task)
        findBar.apply(findState)
    }

    func rerunFindIfOpen() {
        guard findState.isOpen else { return }
        updateFindQuery(lastFindQuery)
    }

    func findHighlight(for row: Int) -> (ranges: [Range<Int>], activeIndex: Int?) {
        let ranges = findMatchRanges[row] ?? []
        guard !ranges.isEmpty, case .open(_, let matches, let current) = findState,
            matches.indices.contains(current), matches[current] == row
        else { return (ranges, nil) }
        let activeOccurrence = matches[..<current].count { $0 == row }
        return (ranges, activeOccurrence)
    }

    private func finishFind(query: String, result: DiffFindMatcher.Result) {
        findMatchRanges = result.rangesByRow
        findState = .open(query: query, matches: result.rows, current: 0)
        findBar.apply(findState)
        refreshDiffCells()
        if let firstRow = result.rows.first {
            scrollToDocumentRow(firstRow)
        }
    }

    private func stepFindMatch(delta: Int) {
        guard case .open(let query, let matches, let current) = findState, !matches.isEmpty else { return }
        let count = matches.count
        let next = ((current + delta) % count + count) % count
        findState = .open(query: query, matches: matches, current: next)
        findBar.apply(findState)
        refreshDiffCells()
        scrollToDocumentRow(matches[next])
    }

    private func applyFindVisibility() {
        let open = findState.isOpen
        findBar.isHidden = !open
        findBarHeight.constant = open ? DiffFindBar.height : 0
        findBar.apply(findState)
    }

    func handleFindKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, isFocusInsideSelf else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()
        if key == "f", flags == [.command] {
            openFind()
            return true
        }
        guard findState.isOpen else { return false }
        if key == "g", flags == [.command] {
            findNext()
            return true
        }
        if key == "g", flags == [.command, .shift] {
            findPrevious()
            return true
        }
        if event.keyCode == 53, flags.isEmpty {
            closeFind()
            return true
        }
        return false
    }

    private var isFocusInsideSelf: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: self)
    }
}
