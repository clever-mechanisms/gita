import AppKit
import GitaCore

/// A file's diff in the review, laid out like GitHub's: the lines, and between them the discussions, the pending
/// review's comments and the box being written. Pointing at a line shows a + in its gutter; clicking it (or
/// double-clicking the line) opens the comment box right under that line. Long lines scroll sideways; the cards keep
/// to the visible width and follow the scroll, so they never slide out of view.
@MainActor
final class ReviewDiffView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    /// What one file's page shows.
    struct Content {
        var patch: String
        var path: String
        var threads: [ReviewThread]
        var pending: [LineComment]
        var viewer: String?
        /// The pull request takes comments now: open, loaded, nothing in flight.
        var canWrite: Bool
        /// The pull request takes comments at all (it is open); false closes any box being written.
        var takesComments: Bool
        var inReview: Bool
    }

    private static let lineHeight: CGFloat = 21
    /// Room after the line numbers for the + so it never covers the code.
    static let plusLane: CGFloat = 22
    private static let cardInsets = NSEdgeInsets(top: 6, left: 12, bottom: 8, right: 12)
    private static let cellID = NSUserInterfaceItemIdentifier("reviewDiffLine")

    let table = ReviewDiffTable()
    let editor = ReviewLineEditorCard()
    private let scroll = NSScrollView()
    private(set) var lines: [DiffLine] = []
    private(set) var rows: [ReviewDiffRow] = []
    private(set) var content: Content?
    private var parsedPatch: String?
    /// The comment or reply box open, if any.
    private(set) var box = ReviewDiffBox.none
    private var cards: [String: NSView] = [:]
    private var cardWidth: CGFloat = 0
    /// The leading edges of the cards on screen, moved with a sideways scroll.
    private var cardLeadings: [NSLayoutConstraint] = []
    private var longestLine = 0
    var actions = ReviewActions()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("diff"))
        column.resizingMask = []
        table.addTableColumn(column)
        table.headerView = nil
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.style = .plain
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.commentableRow = { [weak self] row in self?.commentableLine(row) != nil }
        table.onPlus = { [weak self] row in self?.startComment(row: row) }
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.window
        Deck.pin(scroll, in: self)
        editor.onCancel = { [weak self] in self?.closeEditor() }
        editor.onSend = { [weak self] text, toReview in self?.send(text, toReview: toReview) }
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("ReviewDiffView is built in code") }

    /// Shows a file. A box being written stays open, with its text, while the same file reloads or a write is in
    /// flight (`canSend` holds its buttons meanwhile); another file closes it, and so do new lines under a line
    /// comment's box (its line moved).
    func show(_ content: Content) {
        let sameFile = self.content?.path == content.path
        self.content = content
        let linesChanged = parsedPatch != content.patch || !sameFile
        if linesChanged {
            parsedPatch = content.patch
            lines = ReviewDiffRows.visible(UnifiedDiff.parse(content.patch).lines)
            longestLine = lines.reduce(0) { max($0, $1.text.utf16.count) }
        }
        box = box.kept(showing: content, sameFile: sameFile, linesChanged: linesChanged)
        editor.canSend = content.canWrite
        rebuild(keepingScroll: sameFile)
    }

    // MARK: Writing

    /// The commentable line at a table row.
    func commentableLine(_ row: Int) -> DiffLine? {
        guard content?.canWrite == true, rows.indices.contains(row), case .line(let index) = rows[row],
            LineComment.anchor(lines[index]) != nil
        else { return nil }
        return lines[index]
    }

    func startComment(row: Int) {
        guard commentableLine(row) != nil, case .line(let index) = rows[row], let content else { return }
        box = .comment(line: index)
        let name = ReviewDiffRows.lineName(lines[index]) ?? ""
        editor.begin(.comment(line: name, inReview: content.inReview), viewer: content.viewer)
        rebuild(keepingScroll: true)
        focusEditor()
    }

    func startReply(_ thread: ReviewThread) {
        guard let content, content.canWrite else { return }
        box = .reply(threadID: thread.id)
        editor.begin(.reply, viewer: content.viewer)
        rebuild(keepingScroll: true)
        focusEditor()
    }

    func closeEditor() {
        box = .none
        rebuild(keepingScroll: true)
    }

    private func send(_ text: String, toReview: Bool) {
        switch box {
        case .reply(let id):
            if let thread = content?.threads.first(where: { $0.id == id }) { actions.sendReply(thread, text) }
        case .comment(let index) where lines.indices.contains(index):
            let line = lines[index]
            if toReview { actions.addToReview(text, line) } else { actions.commentNow(text, line) }
        case .comment, .none: break
        }
        closeEditor()
    }

    private func focusEditor() {
        guard
            let row = rows.firstIndex(where: {
                if case .editor = $0 { true } else if case .reply = $0 { true } else { false }
            })
        else { return }
        table.scrollRowToVisible(row)
        window?.makeFirstResponder(editor.text)
    }

    @objc private func doubleClicked() { startComment(row: table.clickedRow) }

    // MARK: Rows

    private func rebuild(keepingScroll: Bool) {
        guard let content else { return }
        let origin = scroll.contentView.bounds.origin
        rows = ReviewDiffRows.build(
            lines: lines, threads: content.threads.filter { $0.path == content.path }, pending: content.pending,
            box: box)
        cards.removeAll()
        let visible = scroll.contentView.bounds.width
        cardWidth = max(240, visible - Self.cardInsets.left - Self.cardInsets.right)
        table.tableColumns.first?.width =
            DiffDocumentBuilder.columnWidth(longestLine: longestLine, minimum: visible)
            + Self.plusLane
        cardLeadings.removeAll()
        table.reloadData()
        table.hidePlus()
        scroll.contentView.scroll(to: keepingScroll ? origin : .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Cards wrap at the new width.
    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged, content != nil { rebuild(keepingScroll: true) }
    }

    private func card(for row: ReviewDiffRow) -> NSView? {
        if let card = cards[row.key] { return card }
        guard let content else { return nil }
        let card: NSView
        switch row {
        case .line: return nil
        case .editor, .reply: card = editor
        case .thread(let thread):
            card = ReviewDiffCards.thread(thread, width: cardWidth, canWrite: content.canWrite, actions: actions) {
                [weak self] in self?.startReply(thread)
            }
        case .pending(let comment):
            card = ReviewDiffCards.pending(comment, viewer: content.viewer, width: cardWidth, actions: actions)
        }
        cards[row.key] = card
        return card
    }

    func numberOfRows(in _: NSTableView) -> Int { rows.count }

    func tableView(_: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row), let card = card(for: rows[row]) else { return Self.lineHeight }
        let width = card.widthAnchor.constraint(equalToConstant: cardWidth)
        width.isActive = card === editor
        defer { if card === editor { width.isActive = false } }
        return ceil(card.fittingSize.height) + Self.cardInsets.top + Self.cardInsets.bottom
    }

    func tableView(_ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        if case .line(let index) = rows[row] {
            let cell = tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? DiffCell ?? DiffCell()
            cell.identifier = Self.cellID
            cell.textInset = Self.plusLane
            cell.line = lines[index]
            cell.toolTip = lines[index].text.count > 120 ? lines[index].text : nil
            return cell
        }
        guard let card = card(for: rows[row]) else { return nil }
        let holder = NSView()
        card.removeFromSuperview()
        holder.addSubview(card)
        card.translatesAutoresizingMaskIntoConstraints = false
        let leading = card.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: cardLeft)
        NSLayoutConstraint.activate([
            leading, card.topAnchor.constraint(equalTo: holder.topAnchor, constant: Self.cardInsets.top),
            card.widthAnchor.constraint(equalToConstant: cardWidth),
        ])
        cardLeadings.removeAll { $0.firstItem == nil || ($0.firstItem as? NSView)?.superview == nil }
        cardLeadings.append(leading)
        return holder
    }

    /// Where a card starts: at the inset from the visible left edge, however far the lines are scrolled.
    private var cardLeft: CGFloat { Self.cardInsets.left + scroll.contentView.bounds.minX }

    @objc private func scrolled() {
        let left = cardLeft
        for leading in cardLeadings where leading.constant != left { leading.constant = left }
    }
}

/// The diff's table: it shows a + over the gutter of the commentable line under the pointer.
@MainActor
final class ReviewDiffTable: NSTableView {
    var commentableRow: (Int) -> Bool = { _ in false }
    var onPlus: (Int) -> Void = { _ in }
    private var hoveredRow = -1
    private(set) lazy var plus: PartsButton = {
        let button = PartsButton(
            [.symbol("plus", color: Deck.onAccent, size: 10)], background: .accent,
            accessibility: String(localized: "Add a comment on this line")
        ) { [weak self] in
            guard let self, self.hoveredRow >= 0 else { return }
            self.onPlus(self.hoveredRow)
        }
        button.fixedHeight = 18
        button.horizontalPadding = 4
        button.cornerRadius = 5
        button.toolTip = String(localized: "Add a comment on this line")
        button.isHidden = true
        addSubview(button)
        return button
    }()

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        showPlus(at: row(at: convert(event.locationInWindow, from: nil)))
    }
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if !plus.isHovering { hidePlus() }
    }

    func showPlus(at row: Int) {
        guard row >= 0, commentableRow(row) else {
            if row != hoveredRow { hidePlus() }
            return
        }
        hoveredRow = row
        let rect = rect(ofRow: row)
        // In its own lane just right of the line numbers, as on GitHub: not over the grey gutter, not over the code.
        plus.frame = NSRect(x: DiffCell.gutterWidth + 3, y: rect.minY + (rect.height - 18) / 2, width: 20, height: 18)
        // Row views added since sit above it; it must take the click, so it goes to the front.
        addSubview(plus, positioned: .above, relativeTo: nil)
        plus.isHidden = false
    }
    func hidePlus() {
        hoveredRow = -1
        plus.isHidden = true
    }
}
