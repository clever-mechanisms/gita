import AppKit
import GitaCore

/// Streaming file blame view (`§6c`): age heat bars (`▇▅▂`), block commit metadata, click to select commit in
/// history, `⌥`-click or `◀ Blame prior revision` to walk back in history.
@MainActor
final class BlameView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private enum Metrics {
        static let headerHeight: CGFloat = 28
        static let rowHeight: CGFloat = 21
        static let buttonHeight: CGFloat = 20
        static let shortSHA = 7
    }
    private static let cellID = NSUserInterfaceItemIdentifier("blame.cell")
    private static let rowID = NSUserInterfaceItemIdentifier("blame.row")

    var onSelectCommit: ((String) -> Void)?
    var onBlamePrior: ((String, String) -> Void)?
    var onShowLineHistory: ((LineRangeSpec) -> Void)?
    var onCopyPermalink: ((String, String?, ClosedRange<Int>?) -> Void)?
    var canCopyPermalink: (() -> Bool)?
    var onClose: (() -> Void)?
    var currentModifiers: () -> NSEvent.ModifierFlags = { NSApp.currentEvent?.modifierFlags ?? [] }

    let table = NSTableView()
    private let scroll: NSScrollView
    private let titleLabel = Deck.label("", font: Theme.captionEmphasis, color: Theme.text)
    private let progressLabel = Deck.label("", font: Theme.caption, color: Theme.secondaryText)
    let priorButton = PartsButton(
        [
            .symbol("chevron.left", color: Theme.secondaryText, size: 9.5),
            .text(String(localized: "Blame prior revision"), font: Theme.caption, color: Theme.text),
        ],
        background: .hover, accessibility: String(localized: "Blame prior revision"))
    let closeButton = PartsButton(
        [.symbol("xmark", color: Theme.secondaryText, size: 10)],
        background: .hover, accessibility: String(localized: "Close blame"))
    private let emptyLabel = Deck.label("", font: Theme.body, color: Theme.secondaryText)

    private var partialDocument: BlameDocument?
    var document: BlameDocument? { load.document ?? partialDocument }
    private(set) var currentPath: String?
    var detailSelectionPath: String?
    private(set) var selectedLineIndex: Int?
    var load = BlameLoad.idle
    private var fontSize: CGFloat = CodeFont.diffSize()
    private var tabWidth: Int = CodeFont.tabWidth()

    override init(frame frameRect: NSRect) {
        scroll = Style.scroll(table, horizontal: true)
        super.init(frame: frameRect)
        wantsLayer = true
        configureHeader()
        configureTable()
        buildLayout()
        setAccessibilityIdentifier("blame.view")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("BlameView is built in code") }

    isolated deinit { load.cancel() }

    private func configureHeader() {
        for button in [priorButton, closeButton] {
            button.fixedHeight = Metrics.buttonHeight
            button.horizontalPadding = 6
            button.cornerRadius = 5
        }
        priorButton.onClick = { [weak self] in self?.triggerPriorRevision() }
        closeButton.onClick = { [weak self] in self?.onClose?() }
        priorButton.setAccessibilityIdentifier("blame.priorButton")
        closeButton.setAccessibilityIdentifier("blame.closeButton")
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        progressLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func configureTable() {
        let column = NSTableColumn(identifier: .init("blame"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Metrics.rowHeight
        table.intercellSpacing = .zero
        table.style = .plain
        table.backgroundColor = Theme.window
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clickedTable)
        table.setAccessibilityLabel(String(localized: "File blame"))
        table.setAccessibilityIdentifier("blame.table")
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
    }

    private func buildLayout() {
        let headerRow = Deck.hstack([titleLabel, progressLabel, Deck.spacer(), priorButton, closeButton], spacing: 8)
        headerRow.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 8)
        let header = RowView()
        header.hoverEnabled = false
        header.bottomSeparator = Theme.separator
        Deck.pin(headerRow, in: header, insets: NSEdgeInsets(top: 0, left: 0, bottom: 1, right: 0))

        emptyLabel.alignment = .center
        emptyLabel.isHidden = true

        for child in [header, scroll, emptyLabel] as [NSView] {
            addSubview(child)
            child.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            header.heightAnchor.constraint(equalToConstant: Metrics.headerHeight),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24),
        ])
    }

    func showLoading(path: String, revision: String?, partial: BlameDocument? = nil) {
        currentPath = path
        updateTypography()
        titleLabel.stringValue = Self.headerTitle(path: path, revision: revision)
        progressLabel.stringValue = String(localized: "Loading blame…")
        progressLabel.isHidden = false
        if let partial {
            partialDocument = partial
            emptyLabel.isHidden = true
            scroll.isHidden = false
            table.reloadData()
        } else {
            partialDocument = nil
            scroll.isHidden = true
            emptyLabel.stringValue = String(localized: "Loading blame…")
            emptyLabel.isHidden = false
        }
        updatePriorButton()
    }

    func showLoaded(_ doc: BlameDocument) {
        currentPath = doc.path
        updateTypography()
        partialDocument = nil
        titleLabel.stringValue = Self.headerTitle(path: doc.path, revision: doc.revision)
        progressLabel.stringValue = ""
        progressLabel.isHidden = true
        let empty = doc.lines.isEmpty || doc.annotations.isEmpty
        emptyLabel.isHidden = !empty
        if empty { emptyLabel.stringValue = String(localized: "Empty file") }
        scroll.isHidden = empty
        table.reloadData()
        updatePriorButton()
    }

    func showFailed(_ error: BlameError, path: String, revision: String?) {
        currentPath = path
        partialDocument = nil
        titleLabel.stringValue = Self.headerTitle(path: path, revision: revision)
        progressLabel.stringValue = ""
        progressLabel.isHidden = true
        scroll.isHidden = true
        emptyLabel.stringValue = load.error?.localizedDescription ?? error.localizedDescription
        emptyLabel.isHidden = false
        updatePriorButton()
    }

    private func updateTypography() {
        fontSize = CodeFont.diffSize()
        tabWidth = CodeFont.tabWidth()
    }

    private func updatePriorButton() {
        let target = load.isLoading ? nil : resolvedPriorTarget()
        priorButton.isEnabled = target != nil
        priorButton.alphaValue = target != nil ? 1 : 0.45
        priorButton.toolTip = target.map {
            String(localized: "Blame \($0.path) at \($0.commit.prefix(Metrics.shortSHA))")
        }
    }

    func resolvedPriorTarget() -> (commit: String, path: String)? {
        guard let document else { return nil }
        if let selectedLineIndex, let prior = document.priorRevision(at: selectedLineIndex) {
            return prior
        }
        if let revision = document.revision {
            return (revision + "^", document.path)
        }
        return nil
    }

    private func triggerPriorRevision() {
        guard let target = resolvedPriorTarget() else { return }
        onBlamePrior?(target.commit, target.path)
    }

    static func headerTitle(path: String, revision: String?) -> String {
        let revLabel = revision.map { String($0.prefix(Metrics.shortSHA)) } ?? String(localized: "Working Tree")
        return String(localized: "Blame · \(path) @ \(revLabel)")
    }

    @objc private func clickedTable() {
        let row = table.clickedRow
        performClickOnRow(at: row, optionPressed: currentModifiers().contains(.option))
    }

    func performClickOnRow(at row: Int, optionPressed: Bool) {
        guard let document, document.annotations.indices.contains(row) else { return }
        selectedLineIndex = row
        updatePriorButton()
        refreshBlockHighlights()
        if optionPressed, let prior = document.priorRevision(at: row) {
            onBlamePrior?(prior.commit, prior.path)
            return
        }
        if let commit = document.annotations[row].commit, !commit.isUncommitted {
            onSelectCommit?(commit.id)
        }
    }

    private func refreshBlockHighlights() {
        let range = selectedLineIndex.flatMap { document?.blockRange(at: $0) }
        table.enumerateAvailableRowViews { rowView, row in
            (rowView.view(atColumn: 0) as? BlameCell)?.isBlockHighlighted = range?.contains(row) == true
        }
    }

    override func cancelOperation(_: Any?) { onClose?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == KeyPress.escape {
            onClose?()
            return
        }
        super.keyDown(with: event)
    }

    // MARK: NSTableViewDataSource & NSTableViewDelegate

    func numberOfRows(in _: NSTableView) -> Int { document?.annotations.count ?? 0 }

    func tableView(_ tableView: NSTableView, rowViewForRow _: Int) -> NSTableRowView? {
        DeckTableRowView.reused(in: tableView, id: Self.rowID)
    }

    func tableView(_ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        guard let document, document.annotations.indices.contains(row) else { return nil }
        let cell = tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? BlameCell ?? BlameCell()
        cell.identifier = Self.cellID
        let annotation = document.annotations[row]
        cell.fontSize = fontSize
        cell.tabWidth = tabWidth
        cell.heatLevel = annotation.commit.map { document.heatLevel(for: $0.date) } ?? 0
        cell.isBlockHighlighted = selectedLineIndex.map { document.blockRange(at: $0).contains(row) } ?? false
        cell.annotation = annotation
        return cell
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow >= 0 ? table.clickedRow : (selectedLineIndex ?? -1)
        guard let document, document.annotations.indices.contains(row) else { return }
        let lineNumber = row + 1
        addLineHistoryItem(to: menu, document: document, lineNumber: lineNumber)
        addPermalinkItem(to: menu, document: document, lineNumber: lineNumber)
    }

    private func addLineHistoryItem(to menu: NSMenu, document: BlameDocument, lineNumber: Int) {
        guard let onShowLineHistory else { return }
        let spec = LineRangeSpec(
            path: document.path, startLine: lineNumber, endLine: lineNumber, revision: document.revision)
        menu.addItem(
            MenuAction(String(localized: "Line History…"), symbol: "doc.text.magnifyingglass") {
                onShowLineHistory(spec)
            })
    }

    private func addPermalinkItem(to menu: NSMenu, document: BlameDocument, lineNumber: Int) {
        guard let onCopyPermalink, canCopyPermalink?() ?? true else { return }
        menu.addItem(
            MenuAction(String(localized: "Copy Permalink"), symbol: "link") {
                onCopyPermalink(document.path, document.revision, lineNumber...lineNumber)
            })
    }
}
