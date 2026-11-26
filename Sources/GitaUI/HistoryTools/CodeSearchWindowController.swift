import AppKit
import GitaCore

/// Native macOS utility window for Git Pickaxe code search (`git log -S` literal and `-G` regex).
@MainActor
final class CodeSearchWindowController: NSWindowController, NSWindowDelegate, NSSearchFieldDelegate {
    private static let rowID = NSUserInterfaceItemIdentifier("codeSearch.row")
    private static let cellID = NSUserInterfaceItemIdentifier("codeSearch.cell")

    let presenter: CodeSearchPresenter
    var onJumpToCommit: ((String) -> Void)?

    private let repositoryRoot: URL?
    private let repositoryName: String
    private let queryField = NSSearchField()
    private let modeControl = NSSegmentedControl()
    private let ignoreCaseButton = NSButton(
        checkboxWithTitle: String(localized: "Ignore Case"), target: nil, action: nil)
    private let pathField = NSTextField()
    private let searchButton: PartsButton
    private let spinner = NSProgressIndicator()
    private let statusLabel = Deck.label(
        "", font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), color: Theme.secondaryText)
    private let commitTitle = Deck.label("", font: Theme.title, color: Theme.text)
    private let commitMeta = Deck.caption("")
    private let jumpButton: PartsButton
    private let copySHAButton: PartsButton
    private var listPane: HistoryToolTablePane?
    private var detailPane: HistoryToolDetailPane?

    convenience init(service: GitService, repositoryRoot: URL? = nil, repositoryName: String? = nil) {
        let name = repositoryName ?? repositoryRoot?.lastPathComponent ?? String(localized: "Repository")
        self.init(
            presenter: CodeSearchPresenter(service: service), repositoryName: name, repositoryRoot: repositoryRoot)
    }

    init(presenter: CodeSearchPresenter, repositoryName: String, repositoryRoot: URL? = nil) {
        self.repositoryRoot = repositoryRoot
        self.repositoryName = repositoryName
        self.presenter = presenter
        self.searchButton = PartsButton(
            [
                .symbol("magnifyingglass", color: Deck.onAccent, size: 11),
                .text(String(localized: "Search"), font: Theme.bodyEmphasis, color: Deck.onAccent),
            ],
            background: .accent,
            accessibility: String(localized: "Search code history")
        )
        self.jumpButton = PartsButton.quiet(String(localized: "Jump to Commit"), symbol: "arrow.up.right.square") {}
        self.copySHAButton = PartsButton.quiet(String(localized: "Copy SHA"), symbol: "doc.on.doc") {}
        super.init(window: nil)
        configureSearchActions()
        presenter.onChange = { [weak self] in self?.render() }
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    /// Shows the Code Search window, optionally prefilling an initial query or path filter.
    func show(initialPattern: String? = nil, pathFilter: String? = nil) {
        let win = prepareWindow()
        AuxiliaryWindowActivation.show(win)
        if let initialPattern {
            queryField.stringValue = initialPattern
            presenter.setPattern(initialPattern)
        }
        if let pathFilter {
            pathField.stringValue = pathFilter
            presenter.setPathFilter(pathFilter)
        }
        win.makeFirstResponder(queryField)
        if let initialPattern, !initialPattern.isEmpty {
            presenter.search()
        }
    }

    @discardableResult
    func prepareWindow() -> NSWindow {
        if let window { return window }
        let win = makeWindow()
        self.window = win
        render()
        return win
    }

    func windowWillClose(_: Notification) {
        presenter.cancel()
        AuxiliaryWindowActivation.closing(window)
    }

    private func configureSearchActions() {
        searchButton.fixedHeight = 24
        searchButton.horizontalPadding = 10
        searchButton.onClick = { [weak self] in self?.runSearch() }
        jumpButton.onClick = { [weak self] in self?.jumpToSelectedCommit() }
        copySHAButton.onClick = { [weak self] in self?.copySelectedSHA() }
        searchButton.setAccessibilityIdentifier("codeSearch.search")
        jumpButton.setAccessibilityIdentifier("codeSearch.jump")
        copySHAButton.setAccessibilityIdentifier("codeSearch.copySHA")
    }

    private func makeWindow() -> NSWindow {
        let list = HistoryToolTablePane(
            columnID: "codeSearch.result",
            rowHeight: CodeSearchRowCell.rowHeight,
            accessibilityLabel: String(localized: "Code search results"),
            accessibilityID: "codeSearch.table"
        )
        list.table.dataSource = self
        list.table.delegate = self
        list.table.target = self
        list.table.doubleAction = #selector(doubleClickedRow)
        listPane = list

        let actions = Deck.hstack([jumpButton, copySHAButton, Deck.spacer()], spacing: 8)
        let headerStack = Deck.vstack([commitTitle, commitMeta, actions], spacing: 6)
        let detail = HistoryToolDetailPane(
            headerContent: headerStack, showsFileBar: true, repositoryRoot: repositoryRoot)
        detail.fileBar.onSelectFile = { [weak self] path in self?.presenter.selectFile(path) }
        detailPane = detail

        return HistoryToolChrome.makeSplitWindow(
            HistoryToolChrome.SplitWindowSpec(
                title: String(localized: "Code Search · \(repositoryName)"),
                size: NSSize(width: 1_020, height: 620),
                minSize: NSSize(width: 740, height: 420),
                topBar: makeSearchControls(),
                list: list,
                detail: detail,
                dividerPosition: 410
            ),
            delegate: self
        )
    }

    private func makeSearchControls() -> NSView {
        let container = RowView()
        container.hoverEnabled = false
        container.fill = Theme.inset

        queryField.placeholderString = String(localized: "Search added or removed code (e.g. func parse)")
        queryField.sendsWholeSearchString = true
        queryField.delegate = self
        queryField.target = self
        queryField.action = #selector(submitSearch)
        queryField.setAccessibilityIdentifier("codeSearch.query")

        modeControl.segmentCount = 2
        modeControl.segmentStyle = .rounded
        modeControl.trackingMode = .selectOne
        modeControl.setLabel(String(localized: "Literal (-S)"), forSegment: 0)
        modeControl.setLabel(String(localized: "Regex (-G)"), forSegment: 1)
        modeControl.selectedSegment = 0
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.setAccessibilityIdentifier("codeSearch.mode")

        pathField.placeholderString = String(localized: "Path filter (optional, e.g. Sources/GitaCore)")
        pathField.font = Theme.body
        pathField.delegate = self
        pathField.target = self
        pathField.action = #selector(submitSearch)
        pathField.setAccessibilityIdentifier("codeSearch.path")

        ignoreCaseButton.font = Theme.caption
        ignoreCaseButton.controlSize = .small
        ignoreCaseButton.target = self
        ignoreCaseButton.action = #selector(ignoreCaseChanged)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.widthAnchor.constraint(equalToConstant: 14).isActive = true
        spinner.heightAnchor.constraint(equalToConstant: 14).isActive = true

        let topRow = Deck.hstack([queryField, modeControl, searchButton], spacing: 8)
        let bottomRow = Deck.hstack([pathField, ignoreCaseButton, spinner, statusLabel], spacing: 10)
        let stack = Deck.vstack([topRow, bottomRow], spacing: 8)
        topRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        bottomRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        queryField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pathField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        Deck.pin(stack, in: container, insets: NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14))
        return container
    }

    private func render() {
        searchButton.isEnabled = presenter.canSearch
        statusLabel.stringValue = presenter.statusSummary
        statusLabel.textColor = presenter.state.errorMessage != nil ? Theme.failure : Theme.secondaryText
        if presenter.state.isSearching {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }

        let matches = presenter.matches
        if let table = listPane?.table {
            table.reloadData()
            if let selectedID = presenter.selectedCommitID,
                let index = matches.firstIndex(where: { $0.commit.id == selectedID })
            {
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            }
        }
        updateEmptyState(count: matches.count)
        updateDetail()
    }

    private func updateEmptyState(count: Int) {
        guard let emptyLabel = listPane?.emptyLabel else { return }
        switch presenter.state {
        case .idle:
            emptyLabel.stringValue = String(localized: "Enter a literal string or regex and press Return")
            emptyLabel.isHidden = false
        case .searching:
            emptyLabel.stringValue = String(localized: "Searching commit diffs…")
            emptyLabel.isHidden = false
        case .failed(_, let message):
            emptyLabel.stringValue = message
            emptyLabel.isHidden = false
        case .results:
            emptyLabel.stringValue = String(localized: "No matching commits found")
            emptyLabel.isHidden = count > 0
        }
    }

    private func updateDetail() {
        guard let detailPane else { return }
        guard let match = presenter.selectedMatch else {
            commitTitle.stringValue = String(localized: "Select a matching commit")
            commitMeta.stringValue = ""
            detailPane.fileBar.apply(paths: [], selected: nil)
            jumpButton.isEnabled = false
            copySHAButton.isEnabled = false
            detailPane.diffView.update(
                "", loading: presenter.state.isSearching, emptyMessage: String(localized: "No diff selected"))
            return
        }
        let shortSHA = String(match.commit.id.prefix(7))
        commitTitle.stringValue = match.commit.subject
        commitMeta.stringValue = "\(shortSHA) · \(match.commit.author) · \(DeckFormat.relative(match.commit.date))"
        detailPane.fileBar.apply(paths: match.matchedFiles, selected: presenter.diffState.selectedPath)
        jumpButton.isEnabled = onJumpToCommit != nil
        copySHAButton.isEnabled = true

        switch presenter.diffState {
        case .idle:
            detailPane.diffView.update("", loading: false, emptyMessage: String(localized: "No diff preview"))
        case .loading:
            detailPane.diffView.update("", loading: true, emptyMessage: String(localized: "Loading file diff…"))
        case .loaded(_, let path, let diff):
            detailPane.diffView.update(
                diff, loading: false, emptyMessage: String(localized: "No diff preview"), path: path)
        case .failed(_, _, let message):
            detailPane.diffView.update("", loading: false, emptyMessage: message)
        }
    }

    @objc private func submitSearch() { runSearch() }

    private func runSearch() {
        presenter.setPattern(queryField.stringValue)
        presenter.setPathFilter(pathField.stringValue)
        presenter.search()
    }

    @objc private func modeChanged() {
        presenter.setMode(modeControl.selectedSegment == 1 ? .regex : .literal)
    }

    @objc private func ignoreCaseChanged() {
        presenter.setIgnoreCase(ignoreCaseButton.state == .on)
    }

    func controlTextDidChange(_: Notification) {
        presenter.setPattern(queryField.stringValue)
        presenter.setPathFilter(pathField.stringValue)
    }

    @objc private func doubleClickedRow() { jumpToSelectedCommit() }

    private func jumpToSelectedCommit() {
        guard let id = presenter.selectedMatch?.commit.id else { return }
        onJumpToCommit?(id)
    }

    private func copySelectedSHA() {
        guard let id = presenter.selectedMatch?.commit.id else { return }
        Deck.copy(id)
    }
}

extension CodeSearchWindowController: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in _: NSTableView) -> Int { presenter.matches.count }

    public func tableView(_ tableView: NSTableView, rowViewForRow _: Int) -> NSTableRowView? {
        DeckTableRowView.reused(in: tableView, id: Self.rowID)
    }

    public func tableView(_ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        guard presenter.matches.indices.contains(row) else { return nil }
        let cell =
            tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? CodeSearchRowCell
            ?? CodeSearchRowCell()
        cell.identifier = Self.cellID
        cell.apply(presenter.matches[row])
        return cell
    }

    public func tableViewSelectionDidChange(_: Notification) {
        guard let row = listPane?.table.selectedRow else { return }
        presenter.select(commitID: presenter.matches.indices.contains(row) ? presenter.matches[row].commit.id : nil)
    }
}

/// One matched commit row with subject, monospaced SHA, file badge, and matched file/snippet preview.
@MainActor
private final class CodeSearchRowCell: NSTableCellView {
    static let rowHeight: CGFloat = 64

    private let subjectLabel = Deck.label("", font: Theme.bodyEmphasis, color: Theme.text)
    private let metaLabel = Deck.label("", font: Theme.mono, color: Theme.secondaryText)
    private let fileCountPill = HistoryToolBadgePill(monospacedDigits: true)
    private let previewLabel = Deck.label("", font: Theme.mono, color: Theme.secondaryText)
    private let dateLabel = Deck.label(
        "", font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), color: Theme.tertiaryText)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        dateLabel.setContentHuggingPriority(.required, for: .horizontal)
        let top = Deck.hstack([subjectLabel, Deck.spacer(), fileCountPill, dateLabel], spacing: 6)
        HistoryToolChrome.pinRowStack([top, metaLabel, previewLabel], in: self)
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    func apply(_ match: PickaxeMatch) {
        subjectLabel.stringValue = match.commit.subject
        metaLabel.stringValue = HistoryToolChrome.commitMetaText(for: match.commit)
        dateLabel.stringValue = DeckFormat.relative(match.commit.date)
        let count = match.matchedFiles.count
        fileCountPill.isHidden = count == 0
        if count > 0 {
            let label = count == 1 ? String(localized: "1 file") : String(localized: "\(count) files")
            fileCountPill.apply(title: label, color: Theme.working)
        }
        let preview = match.matchedFiles.joined(separator: ", ")
        previewLabel.stringValue = preview
        previewLabel.isHidden = preview.isEmpty
        previewLabel.textColor = Theme.secondaryText
    }
}
