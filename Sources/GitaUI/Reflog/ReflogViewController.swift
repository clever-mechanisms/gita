import AppKit
import GitaCore

/// Embeddable inline controller for browsing Git reflog entries, inspecting orphaned commits,
/// viewing per-file commit diffs, and safely recovering via Create Branch or Reviewed Reset.
@MainActor
final class ReflogViewController: NSViewController, NSSearchFieldDelegate {
    private static let rowID = NSUserInterfaceItemIdentifier("reflog.table.row")

    let presenter: ReflogPresenter
    var onJumpToCommit: ((String) -> Void)? {
        didSet { if isViewLoaded { updateDetailPane() } }
    }
    var onRepositoryMutated: (() -> Void)?
    var onBack: (() -> Void)? {
        didSet { headerBar?.onBack = onBack }
    }

    private let service: GitService
    private let repositoryRoot: URL?
    private let repositoryName: String
    private let filterControl = NSSegmentedControl()
    private let searchField = NSSearchField()
    private let refreshButton: PartsButton
    private let statusLabel = Deck.label(
        "", font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), color: Theme.secondaryText)
    private let detailTitle = Deck.label("", font: Theme.title, color: Theme.text)
    private let detailSubtitle = Deck.caption("")
    private let orphanBanner = ReflogOrphanCallout()
    private let createBranchButton: PartsButton
    private let resetButton: PartsButton
    private let jumpButton: PartsButton
    private var headerBar: HistoryToolHeaderBar?
    private var listPane: HistoryToolTablePane?
    private var detailPane: HistoryToolDetailPane?
    private var activeResetSheet: ResetReviewController?

    init(service: GitService, repositoryRoot: URL? = nil, repositoryName: String? = nil) {
        self.service = service
        self.repositoryRoot = repositoryRoot
        self.repositoryName = repositoryName ?? repositoryRoot?.lastPathComponent ?? String(localized: "Repository")
        self.presenter = ReflogPresenter(service: service)
        self.refreshButton = StorageStyle.actionButton(
            String(localized: "Refresh"), symbol: "arrow.clockwise", style: .quiet
        ) {}
        self.createBranchButton = PartsButton.quiet(
            String(localized: "Create Branch Here…"), symbol: "arrow.triangle.branch"
        ) {}
        self.resetButton = PartsButton.quiet(
            String(localized: "Reset Here…"), symbol: "arrow.uturn.backward"
        ) {}
        self.jumpButton = PartsButton.quiet(
            String(localized: "Show in History"), symbol: "arrow.up.right.square"
        ) {}
        super.init(nibName: nil, bundle: nil)
        bindActions()
        presenter.onChange = { [weak self] in self?.render() }
        presenter.onRepositoryMutated = { [weak self] in self?.onRepositoryMutated?() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleThemeChanged), name: .gitaThemeChanged, object: nil)
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    func reload(ref: String = "HEAD") {
        presenter.reload(ref: ref)
    }

    func cancel() {
        activeResetSheet?.close()
        activeResetSheet = nil
        presenter.cancelAll()
    }

    override func loadView() {
        configureHeaderControls()
        let header = HistoryToolHeaderBar(
            HistoryToolHeaderBar.Spec(
                symbol: "clock.arrow.circlepath",
                title: String(localized: "Reflog"),
                subtitle: repositoryName,
                trailing: [filterControl, searchField, refreshButton]
            )
        )
        header.onBack = onBack
        headerBar = header

        let list = HistoryToolTablePane(
            columnID: "reflog.entry",
            rowHeight: ReflogRowCell.rowHeight,
            accessibilityLabel: String(localized: "Reflog entries"),
            accessibilityID: "reflog.table",
            footer: makeStatusFooter()
        )
        list.table.dataSource = self
        list.table.delegate = self
        listPane = list

        let actions = Deck.hstack([createBranchButton, resetButton, jumpButton, Deck.spacer()], spacing: 8)
        let headerStack = Deck.vstack([detailTitle, detailSubtitle, actions], spacing: 6)
        orphanBanner.isHidden = true
        let detail = HistoryToolDetailPane(
            headerContent: headerStack,
            banner: orphanBanner,
            showsFileBar: true,
            repositoryRoot: repositoryRoot
        )
        detail.fileBar.onSelectFile = { [weak self] path in self?.presenter.selectFile(path) }
        detailPane = detail

        view = HistoryToolChrome.makeInlineSplitView(
            HistoryToolChrome.InlineSplitSpec(
                header: header,
                list: list,
                detail: detail,
                dividerPosition: 430
            )
        )
        render()
    }

    private func bindActions() {
        refreshButton.onClick = { [weak self] in self?.presenter.reload() }
        createBranchButton.onClick = { [weak self] in self?.promptCreateBranch() }
        resetButton.onClick = { [weak self] in self?.presentResetReview() }
        jumpButton.onClick = { [weak self] in self?.jumpToSelectedCommit() }
        refreshButton.setAccessibilityIdentifier("reflog.refresh")
        createBranchButton.setAccessibilityIdentifier("reflog.createBranch")
        resetButton.setAccessibilityIdentifier("reflog.resetHere")
        jumpButton.setAccessibilityIdentifier("reflog.jumpCommit")
    }

    private func configureHeaderControls() {
        let segments = ReflogFilter.ordered.map {
            HistoryToolChrome.SegmentSpec(title: $0.title, symbol: $0.symbol)
        }
        HistoryToolChrome.configureSegmentedControl(
            filterControl, segments: segments, target: self, action: #selector(filterSegmentChanged))
        filterControl.setAccessibilityIdentifier("reflog.filter")

        searchField.placeholderString = String(localized: "Filter reflog")
        searchField.controlSize = .small
        searchField.font = Theme.body
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.setAccessibilityIdentifier("reflog.search")
        searchField.widthAnchor.constraint(equalToConstant: 170).isActive = true
    }

    private func makeStatusFooter() -> NSView {
        let bar = RowView()
        bar.hoverEnabled = false
        bar.fill = Theme.inset
        let topBorder = Deck.separator()
        bar.addSubview(topBorder)
        topBorder.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            topBorder.topAnchor.constraint(equalTo: bar.topAnchor),
            topBorder.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            topBorder.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
        ])
        Deck.pin(statusLabel, in: bar, insets: NSEdgeInsets(top: 5, left: 12, bottom: 5, right: 12))
        return bar
    }

    @objc private func handleThemeChanged() {
        guard isViewLoaded else { return }
        view.needsDisplay = true
        render()
    }

    private func render() {
        guard isViewLoaded else { return }
        let entries = presenter.visibleEntries
        let selectedIndex = presenter.selectedEntryID.flatMap { selectedID in
            entries.firstIndex { $0.id == selectedID }
        }
        HistoryToolChrome.reloadTable(listPane?.table, selectedIndex: selectedIndex)
        statusLabel.stringValue = presenter.statusSummary
        updateEmptyState(entriesCount: entries.count)
        updateDetailPane()
    }

    private func updateEmptyState(entriesCount: Int) {
        guard let emptyState = listPane?.emptyState else { return }
        if presenter.loadState.isLoading {
            emptyState.apply(
                hidden: false,
                symbol: "clock.arrow.circlepath",
                title: String(localized: "Loading reflog…"),
                tint: Theme.working
            )
        } else if let error = presenter.loadState.errorMessage {
            emptyState.apply(
                hidden: false,
                symbol: "exclamationmark.triangle",
                title: error,
                tint: Theme.failure
            )
        } else if entriesCount == 0 {
            emptyState.apply(
                hidden: false,
                symbol: "clock.arrow.circlepath",
                title: String(localized: "No matching reflog entries"),
                detail: String(localized: "Try clearing the filter or switching to All entries.")
            )
        } else {
            emptyState.isHidden = true
        }
    }

    private func updateDetailPane() {
        guard let detailPane else { return }
        guard let entry = presenter.selectedEntry else {
            renderEmptyDetail(in: detailPane)
            return
        }
        detailTitle.stringValue = entry.subject.isEmpty ? entry.actionSummary : entry.subject
        detailSubtitle.stringValue =
            "\(entry.selector) · \(entry.shortID) · \(entry.actionSummary) · \(entry.author) · \(DeckFormat.relative(entry.date))"
        orphanBanner.isHidden = !entry.isOrphaned
        createBranchButton.isEnabled = true
        resetButton.isEnabled = true
        jumpButton.isEnabled = onJumpToCommit != nil && !entry.isOrphaned
        detailPane.fileBar.apply(paths: presenter.diffState.files, selected: presenter.diffState.selectedPath)
        renderDetailDiff(in: detailPane)
    }

    private func renderEmptyDetail(in detailPane: HistoryToolDetailPane) {
        detailTitle.stringValue = String(localized: "Select a reflog entry")
        detailSubtitle.stringValue = String(localized: "Inspect any prior HEAD state or recover dropped commits.")
        orphanBanner.isHidden = true
        detailPane.fileBar.apply(paths: [], selected: nil)
        for button in [createBranchButton, resetButton, jumpButton] { button.isEnabled = false }
        detailPane.diffView.update(
            "", loading: false, emptyMessage: String(localized: "Select an entry to preview its diff"))
    }

    private struct DiffDisplay {
        let diff: String
        let loading: Bool
        let emptyMessage: String
        let path: String?
    }

    private func renderDetailDiff(in detailPane: HistoryToolDetailPane) {
        let display = Self.diffDisplay(for: presenter.diffState)
        detailPane.diffView.update(
            display.diff, loading: display.loading, emptyMessage: display.emptyMessage, path: display.path)
    }

    private static func diffDisplay(for state: ReflogDiffState) -> DiffDisplay {
        switch state {
        case .loaded(_, _, let path, let diff):
            DiffDisplay(
                diff: diff, loading: false, emptyMessage: String(localized: "Commit has no textual diff"), path: path)
        case .failed(_, _, _, let message):
            DiffDisplay(diff: "", loading: false, emptyMessage: message, path: nil)
        case .idle:
            DiffDisplay(diff: "", loading: false, emptyMessage: String(localized: "No diff available"), path: nil)
        case .loading, .loadingFile:
            DiffDisplay(diff: "", loading: true, emptyMessage: String(localized: "Loading file diff…"), path: nil)
        }
    }

    @objc private func filterSegmentChanged() {
        let index = filterControl.selectedSegment
        guard ReflogFilter.ordered.indices.contains(index) else { return }
        presenter.setFilter(ReflogFilter.ordered[index])
    }

    @objc private func searchChanged() {
        presenter.setSearchQuery(searchField.stringValue)
    }

    func controlTextDidChange(_: Notification) {
        presenter.setSearchQuery(searchField.stringValue)
    }

    private func jumpToSelectedCommit() {
        guard let entry = presenter.selectedEntry else { return }
        onJumpToCommit?(entry.commitID)
    }

    private func promptCreateBranch() {
        guard let window = view.window, let entry = presenter.selectedEntry else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Create Branch at \(entry.shortID)")
        alert.informativeText = String(localized: "Create and switch to a new branch pointing at \(entry.selector).")
        alert.addButton(withTitle: String(localized: "Create Branch"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = presenter.suggestedRecoveryBranchName(for: entry)
        alert.accessoryView = field
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .alertFirstButtonReturn else { return }
                self.createRecoveryBranch(named: field.stringValue, at: entry)
            }
        }
    }

    private func createRecoveryBranch(named rawName: String, at entry: ReflogEntry) {
        let branchName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branchName.isEmpty else { return }
        Task { @MainActor [weak self] in
            await self?.runCreateRecoveryBranch(named: branchName, at: entry)
        }
    }

    private func runCreateRecoveryBranch(named branchName: String, at entry: ReflogEntry) async {
        do {
            try await presenter.createBranch(named: branchName, at: entry)
        } catch {
            if let win = view.window { _ = await NSAlert(error: error).beginSheetModal(for: win) }
        }
    }

    private func presentResetReview() {
        guard let window = view.window, let entry = presenter.selectedEntry else { return }
        let commit = GitCommit(
            id: entry.commitID, parents: [], subject: entry.subject, author: entry.author, date: entry.date)
        let controller = ResetReviewController(
            commit: commit,
            onLoad: { [service] in try await service.resetPreview(to: entry.commitID) },
            onApply: { [weak self, service] preview, mode in
                try await service.reset(preview, mode: mode)
                self?.onRepositoryMutated?()
                self?.presenter.reload()
            }
        )
        guard let sheet = controller.window else { return }
        activeResetSheet = controller
        window.beginSheet(sheet) { [weak self] _ in
            MainActor.assumeIsolated { self?.activeResetSheet = nil }
        }
    }
}

extension ReflogViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in _: NSTableView) -> Int { presenter.visibleEntries.count }

    func tableView(_ tableView: NSTableView, rowViewForRow _: Int) -> NSTableRowView? {
        DeckTableRowView.reused(in: tableView, id: Self.rowID)
    }

    func tableView(_ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        let entries = presenter.visibleEntries
        guard entries.indices.contains(row) else { return nil }
        let cell =
            tableView.makeView(withIdentifier: ReflogRowCell.identifier, owner: nil) as? ReflogRowCell
            ?? ReflogRowCell()
        cell.identifier = ReflogRowCell.identifier
        cell.apply(entries[row])
        return cell
    }

    func tableViewSelectionDidChange(_: Notification) {
        guard let row = listPane?.table.selectedRow else { return }
        let entries = presenter.visibleEntries
        presenter.select(entryID: entries.indices.contains(row) ? entries[row].id : nil)
    }
}

/// Highlight banner shown when the selected reflog entry points to an orphaned/dropped commit.
@MainActor
private final class ReflogOrphanCallout: NSView {
    private let icon = Deck.icon("exclamationmark.triangle.fill", size: 12, color: Theme.needsInputText)
    private let label = Deck.label(
        String(localized: "Orphaned commit — unreachable from any branch or tag. Create a branch to rescue it."),
        font: Theme.captionEmphasis,
        color: Theme.needsInputText
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let row = Deck.hstack([icon, label, Deck.spacer()], spacing: 8)
        Deck.pin(row, in: self, insets: NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 14))
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = Theme.needsInput.withAlphaComponent(0.14).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
