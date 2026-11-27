import AppKit
import GitaCore

/// Embeddable inline controller for Git Pickaxe code search (`git log -S` literal and `-G` regex).
@MainActor
final class CodeSearchViewController: NSViewController, NSSearchFieldDelegate {
    private static let rowID = NSUserInterfaceItemIdentifier("codeSearch.row")
    private static let cellID = NSUserInterfaceItemIdentifier("codeSearch.cell")

    let presenter: CodeSearchPresenter
    var onJumpToCommit: ((String) -> Void)? {
        didSet { if isViewLoaded { updateDetail() } }
    }
    var onBack: (() -> Void)? {
        didSet { headerBar?.onBack = onBack }
    }

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
    private var headerBar: HistoryToolHeaderBar?
    private var listPane: HistoryToolTablePane?
    private var detailPane: HistoryToolDetailPane?

    convenience init(service: GitService, repositoryRoot: URL? = nil, repositoryName: String? = nil) {
        self.init(
            presenter: CodeSearchPresenter(service: service),
            repositoryName: HistoryToolChrome.repositoryDisplayName(repositoryName, root: repositoryRoot),
            repositoryRoot: repositoryRoot
        )
    }

    init(presenter: CodeSearchPresenter, repositoryName: String, repositoryRoot: URL? = nil) {
        self.repositoryRoot = repositoryRoot
        self.repositoryName = repositoryName
        self.presenter = presenter
        self.searchButton = StorageStyle.actionButton(
            String(localized: "Search"), symbol: "magnifyingglass", style: .accent,
            accessibility: String(localized: "Search code history")
        ) {}
        self.jumpButton = PartsButton.quiet(String(localized: "Jump to Commit"), symbol: "arrow.up.right.square") {}
        self.copySHAButton = HistoryToolChrome.copySHAButton {}
        super.init(nibName: nil, bundle: nil)
        configureSearchActions()
        presenter.onChange = { [weak self] in self?.render() }
        HistoryToolChrome.observeTheme(self, selector: #selector(handleThemeChanged))
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    func show(initialPattern: String? = nil, pathFilter: String? = nil) {
        loadViewIfNeeded()
        if let initialPattern {
            queryField.stringValue = initialPattern
            presenter.setPattern(initialPattern)
        }
        if let pathFilter {
            pathField.stringValue = pathFilter
            presenter.setPathFilter(pathFilter)
        }
        focusQuery()
        if let initialPattern, !initialPattern.isEmpty {
            presenter.search()
        }
    }

    func focusQuery() {
        loadViewIfNeeded()
        view.window?.makeFirstResponder(queryField)
    }

    func cancel() {
        presenter.cancel()
    }

    override func loadView() {
        configureSpinner()
        let header = HistoryToolHeaderBar(
            HistoryToolHeaderBar.Spec(
                symbol: "doc.text.magnifyingglass",
                title: String(localized: "Code Search"),
                subtitle: repositoryName,
                trailing: [spinner, statusLabel]
            )
        )
        header.onBack = onBack
        headerBar = header

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

        view = HistoryToolChrome.makeInlineSplitView(
            HistoryToolChrome.InlineSplitSpec(
                header: header,
                subBar: makeSearchControls(),
                list: list,
                detail: detail,
                dividerPosition: 410
            )
        )
        render()
    }

    private func configureSearchActions() {
        searchButton.onClick = { [weak self] in self?.runSearch() }
        jumpButton.onClick = { [weak self] in self?.jumpToSelectedCommit() }
        copySHAButton.onClick = { [weak self] in self?.copySelectedSHA() }
        searchButton.setAccessibilityIdentifier("codeSearch.search")
        jumpButton.setAccessibilityIdentifier("codeSearch.jump")
        copySHAButton.setAccessibilityIdentifier("codeSearch.copySHA")
    }

    private func configureSpinner() {
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.usesThreadedAnimation = false
        spinner.isDisplayedWhenStopped = false
        spinner.widthAnchor.constraint(equalToConstant: 14).isActive = true
        spinner.heightAnchor.constraint(equalToConstant: 14).isActive = true
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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

        HistoryToolChrome.configureSegmentedControl(
            modeControl,
            segments: [
                .init(title: String(localized: "Literal (-S)"), symbol: "text.quote"),
                .init(title: String(localized: "Regex (-G)"), symbol: "asterisk.circle"),
            ],
            target: self,
            action: #selector(modeChanged)
        )
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

        let topRow = Deck.hstack([queryField, modeControl, searchButton], spacing: 8)
        let pathIcon = Deck.icon("folder", size: 11, color: Theme.secondaryText)
        let bottomRow = Deck.hstack([pathIcon, pathField, ignoreCaseButton, Deck.spacer()], spacing: 8)
        let stack = Deck.vstack([topRow, bottomRow], spacing: 8)
        topRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        bottomRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        queryField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pathField.widthAnchor.constraint(equalToConstant: 260).isActive = true

        Deck.pin(stack, in: container, insets: NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14))
        return container
    }

    @objc private func handleThemeChanged() {
        guard isViewLoaded else { return }
        view.needsDisplay = true
        render()
    }

    private func render() {
        guard isViewLoaded else { return }
        searchButton.isEnabled = presenter.canSearch
        statusLabel.stringValue = presenter.statusSummary
        statusLabel.textColor = presenter.state.errorMessage != nil ? Theme.failure : Theme.secondaryText
        if presenter.state.isSearching {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }

        let matches = presenter.matches
        let selectedIndex = presenter.selectedCommitID.flatMap { selectedID in
            matches.firstIndex { $0.commit.id == selectedID }
        }
        HistoryToolChrome.reloadTable(listPane?.table, selectedIndex: selectedIndex)
        updateEmptyState(count: matches.count)
        updateDetail()
    }

    private func updateEmptyState(count: Int) {
        guard let emptyState = listPane?.emptyState else { return }
        switch presenter.state {
        case .idle:
            emptyState.apply(
                hidden: false,
                symbol: "doc.text.magnifyingglass",
                title: String(localized: "Search commit history"),
                detail: String(localized: "Enter a literal string or regex and press Return.")
            )
        case .searching:
            emptyState.apply(
                hidden: false,
                symbol: "magnifyingglass",
                title: String(localized: "Searching commit diffs…"),
                tint: Theme.working
            )
        case .failed(_, let message):
            emptyState.apply(
                hidden: false,
                symbol: "exclamationmark.triangle",
                title: message,
                tint: Theme.failure
            )
        case .results:
            emptyState.apply(
                hidden: count > 0,
                symbol: "magnifyingglass",
                title: String(localized: "No matching commits found"),
                detail: String(localized: "Try broadening your pattern or clearing the path filter.")
            )
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
        commitTitle.stringValue = match.commit.subject
        commitMeta.stringValue = HistoryToolChrome.commitDetailMeta(for: match.commit)
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

extension CodeSearchViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in _: NSTableView) -> Int { presenter.matches.count }

    func tableView(_ tableView: NSTableView, rowViewForRow _: Int) -> NSTableRowView? {
        DeckTableRowView.reused(in: tableView, id: Self.rowID)
    }

    func tableView(_ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        guard presenter.matches.indices.contains(row) else { return nil }
        let cell =
            tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? CodeSearchRowCell
            ?? CodeSearchRowCell()
        cell.identifier = Self.cellID
        cell.apply(presenter.matches[row])
        return cell
    }

    func tableViewSelectionDidChange(_: Notification) {
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
