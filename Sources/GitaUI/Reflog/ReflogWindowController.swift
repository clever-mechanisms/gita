import AppKit
import GitaCore

/// Native macOS utility window for browsing Git reflog entries, inspecting orphaned commits,
/// viewing per-file commit diffs, and safely recovering via Create Branch or Reviewed Reset.
@MainActor
public final class ReflogWindowController: NSWindowController, NSWindowDelegate, NSSearchFieldDelegate {
    private static let refreshIdentifier = NSToolbarItem.Identifier("reflog.refresh")
    private static let filterIdentifier = NSToolbarItem.Identifier("reflog.filter")
    private static let searchIdentifier = NSToolbarItem.Identifier("reflog.search")
    private static let rowID = NSUserInterfaceItemIdentifier("reflog.table.row")

    public let presenter: ReflogPresenter
    public var onJumpToCommit: ((String) -> Void)?
    public var onRepositoryMutated: (() -> Void)?

    private let service: GitService
    private let repositoryRoot: URL?
    private let repositoryName: String
    private let filterControl = NSSegmentedControl()
    private let searchField = NSSearchField()
    private let statusLabel = Deck.label(
        "", font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), color: Theme.secondaryText)
    private let detailTitle = Deck.label("", font: Theme.title, color: Theme.text)
    private let detailSubtitle = Deck.caption("")
    private let orphanBanner = ReflogOrphanCallout()
    private let createBranchButton: PartsButton
    private let resetButton: PartsButton
    private let jumpButton: PartsButton
    private var listPane: HistoryToolTablePane?
    private var detailPane: HistoryToolDetailPane?
    private var activeResetSheet: ResetReviewController?

    public init(service: GitService, repositoryRoot: URL? = nil, repositoryName: String? = nil) {
        self.service = service
        self.repositoryRoot = repositoryRoot
        self.repositoryName = repositoryName ?? repositoryRoot?.lastPathComponent ?? String(localized: "Repository")
        self.presenter = ReflogPresenter(service: service)
        self.createBranchButton = PartsButton.quiet(
            String(localized: "Create Branch Here…"), symbol: "arrow.triangle.branch"
        ) {}
        self.resetButton = PartsButton.quiet(
            String(localized: "Reset Here…"), symbol: "arrow.uturn.backward"
        ) {}
        self.jumpButton = PartsButton.quiet(
            String(localized: "Show in History"), symbol: "arrow.up.right.square"
        ) {}
        super.init(window: nil)
        bindActions()
        presenter.onChange = { [weak self] in self?.render() }
        presenter.onRepositoryMutated = { [weak self] in self?.onRepositoryMutated?() }
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    /// Shows the Reflog Browser window and loads fresh reflog entries on demand.
    public func show(ref: String = "HEAD") {
        let win = prepareWindow()
        win.makeKeyAndOrderFront(nil)
        presenter.reload(ref: ref)
    }

    /// Builds the window hierarchy without ordering on screen (useful for tests).
    @discardableResult
    public func prepareWindow() -> NSWindow {
        if let window { return window }
        let win = makeWindow()
        self.window = win
        render()
        return win
    }

    public func windowWillClose(_: Notification) {
        presenter.cancelAll()
    }

    private func bindActions() {
        createBranchButton.onClick = { [weak self] in self?.promptCreateBranch() }
        resetButton.onClick = { [weak self] in self?.presentResetReview() }
        jumpButton.onClick = { [weak self] in self?.jumpToSelectedCommit() }
        createBranchButton.setAccessibilityIdentifier("reflog.createBranch")
        resetButton.setAccessibilityIdentifier("reflog.resetHere")
        jumpButton.setAccessibilityIdentifier("reflog.jumpCommit")
    }

    private func makeWindow() -> NSWindow {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )
        win.title = String(localized: "Reflog · \(repositoryName)")
        win.minSize = NSSize(width: 720, height: 420)
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.toolbarStyle = .unified
        configureToolbar(on: win)

        let root = ThemedBackgroundView()
        win.contentView = root
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

        let split = DeckSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(list)
        split.addArrangedSubview(detail)
        Deck.pin(split, in: root)
        split.setPosition(430, ofDividerAt: 0)
        win.center()
        return win
    }

    private func configureToolbar(on window: NSWindow) {
        let filters = ReflogFilter.ordered
        filterControl.segmentCount = filters.count
        filterControl.segmentStyle = .rounded
        filterControl.trackingMode = .selectOne
        for (idx, item) in filters.enumerated() {
            filterControl.setLabel(item.title, forSegment: idx)
        }
        filterControl.selectedSegment = 0
        filterControl.target = self
        filterControl.action = #selector(filterSegmentChanged)

        searchField.placeholderString = String(localized: "Filter reflog")
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged)

        let toolbar = NSToolbar(identifier: "GitaReflogBrowser")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
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

    private func render() {
        let entries = presenter.visibleEntries
        if let table = listPane?.table {
            table.reloadData()
            if let selectedID = presenter.selectedEntryID,
                let index = entries.firstIndex(where: { $0.id == selectedID })
            {
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            }
        }
        statusLabel.stringValue = presenter.statusSummary
        updateEmptyState(entriesCount: entries.count)
        updateDetailPane()
    }

    private func updateEmptyState(entriesCount: Int) {
        guard let emptyLabel = listPane?.emptyLabel else { return }
        if presenter.loadState.isLoading {
            emptyLabel.stringValue = String(localized: "Loading reflog…")
            emptyLabel.isHidden = false
        } else if let error = presenter.loadState.errorMessage {
            emptyLabel.stringValue = error
            emptyLabel.isHidden = false
        } else if entriesCount == 0 {
            emptyLabel.stringValue = String(localized: "No matching reflog entries")
            emptyLabel.isHidden = false
        } else {
            emptyLabel.isHidden = true
        }
    }

    private func updateDetailPane() {
        guard let detailPane else { return }
        guard let entry = presenter.selectedEntry else {
            detailTitle.stringValue = String(localized: "Select a reflog entry")
            detailSubtitle.stringValue = String(localized: "Inspect any prior HEAD state or recover dropped commits.")
            orphanBanner.isHidden = true
            detailPane.fileBar.apply(paths: [], selected: nil)
            for button in [createBranchButton, resetButton, jumpButton] { button.isEnabled = false }
            detailPane.diffView.update(
                "", loading: false, emptyMessage: String(localized: "Select an entry to preview its diff"))
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

        switch presenter.diffState {
        case .idle:
            detailPane.diffView.update("", loading: false, emptyMessage: String(localized: "No diff available"))
        case .loading, .loadingFile:
            detailPane.diffView.update("", loading: true, emptyMessage: String(localized: "Loading file diff…"))
        case .loaded(_, _, let path, let diff):
            detailPane.diffView.update(
                diff,
                loading: false,
                emptyMessage: String(localized: "Commit has no textual diff"),
                path: path
            )
        case .failed(_, _, _, let message):
            detailPane.diffView.update("", loading: false, emptyMessage: message)
        }
    }

    @objc private func refreshTriggered() { presenter.reload() }

    @objc private func filterSegmentChanged() {
        let index = filterControl.selectedSegment
        guard ReflogFilter.ordered.indices.contains(index) else { return }
        presenter.setFilter(ReflogFilter.ordered[index])
    }

    @objc private func searchChanged() {
        presenter.setSearchQuery(searchField.stringValue)
    }

    public func controlTextDidChange(_: Notification) {
        presenter.setSearchQuery(searchField.stringValue)
    }

    private func jumpToSelectedCommit() {
        guard let entry = presenter.selectedEntry else { return }
        onJumpToCommit?(entry.commitID)
    }

    private func promptCreateBranch() {
        guard let window, let entry = presenter.selectedEntry else { return }
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
                let branchName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !branchName.isEmpty else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        try await self.presenter.createBranch(named: branchName, at: entry)
                    } catch {
                        if let win = self.window { _ = await NSAlert(error: error).beginSheetModal(for: win) }
                    }
                }
            }
        }
    }

    private func presentResetReview() {
        guard let window, let entry = presenter.selectedEntry else { return }
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

extension ReflogWindowController: NSTableViewDataSource, NSTableViewDelegate, NSToolbarDelegate {
    public func numberOfRows(in _: NSTableView) -> Int { presenter.visibleEntries.count }

    public func tableView(_ tableView: NSTableView, rowViewForRow _: Int) -> NSTableRowView? {
        DeckTableRowView.reused(in: tableView, id: Self.rowID)
    }

    public func tableView(_ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        let entries = presenter.visibleEntries
        guard entries.indices.contains(row) else { return nil }
        let cell =
            tableView.makeView(withIdentifier: ReflogRowCell.identifier, owner: nil) as? ReflogRowCell
            ?? ReflogRowCell()
        cell.identifier = ReflogRowCell.identifier
        cell.apply(entries[row])
        return cell
    }

    public func tableViewSelectionDidChange(_: Notification) {
        guard let row = listPane?.table.selectedRow else { return }
        let entries = presenter.visibleEntries
        presenter.select(entryID: entries.indices.contains(row) ? entries[row].id : nil)
    }

    public func toolbarDefaultItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.filterIdentifier, .flexibleSpace, Self.refreshIdentifier, Self.searchIdentifier]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    public func toolbar(
        _: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar _: Bool
    ) -> NSToolbarItem? {
        switch identifier {
        case Self.filterIdentifier:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = filterControl
            item.label = String(localized: "Filter")
            return item
        case Self.refreshIdentifier:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = String(localized: "Refresh")
            item.toolTip = String(localized: "Refresh reflog")
            item.image = NSImage(
                systemSymbolName: "arrow.clockwise", accessibilityDescription: String(localized: "Refresh"))
            item.isBordered = true
            item.target = self
            item.action = #selector(refreshTriggered)
            return item
        case Self.searchIdentifier:
            let item = NSSearchToolbarItem(itemIdentifier: identifier)
            item.searchField = searchField
            item.label = String(localized: "Search")
            item.preferredWidthForSearchField = 200
            return item
        default:
            return nil
        }
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
