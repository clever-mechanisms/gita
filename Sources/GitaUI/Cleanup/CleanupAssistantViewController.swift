import AppKit
import GitaCore

/// Embeddable Cleanup Assistant view controller for reviewing and removing merged branches,
/// gone upstreams, stale branches, and idle worktrees.
@MainActor
final class CleanupAssistantViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private static let rowID = NSUserInterfaceItemIdentifier("cleanup.table.row")
    private let service: GitService
    private let onDidMutate: () -> Void
    let page: WorkflowPageView
    private var presenter = CleanupAssistantPresenter()
    private var rows: [CleanupRowItem] = []
    private var scan: Task<Void, Never>?
    private let thresholds = [14, 30, 60, 90]
    private let threshold = NSPopUpButton()
    private var filterButtons: [CleanupFilter: PartsButton] = [:]
    private lazy var selectAllButton = PartsButton.quiet(
        String(localized: "Select All"), symbol: "checkmark.circle"
    ) { [weak self] in
        self?.toggleAll()
    }

    var onBack: (() -> Void)? {
        get { page.onBack }
        set { page.onBack = newValue }
    }

    var isCleaning: Bool { presenter.isCleaning }

    init(gitService: GitService, repositoryName: String? = nil, onDidMutate: @escaping () -> Void = {}) {
        service = gitService
        self.onDidMutate = onDidMutate
        page = WorkflowPageView(
            title: String(localized: "Branch & Worktree Cleanup"),
            symbol: "wand.and.stars",
            actionTitle: String(localized: "Clean Selected…"),
            actionSymbol: "trash")
        super.init(nibName: nil, bundle: nil)
        title =
            repositoryName.map { String(localized: "Branch & Worktree Cleanup · \($0)") }
            ?? String(localized: "Branch & Worktree Cleanup")
        page.subtitle.stringValue = String(localized: "Review merged branches, gone upstreams, and idle worktrees.")
        configureHeaderControls()
        configureFilterStrip()
        configureTableAndActions()
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    override func loadView() {
        view = page
    }

    func reload() {
        refresh(clearFailures: true)
    }

    func cancel() {
        scan?.cancel()
    }

    private func configureHeaderControls() {
        for days in thresholds { threshold.addItem(withTitle: String(localized: "\(days) days")) }
        threshold.selectItem(at: 1)
        threshold.controlSize = .small
        threshold.font = Theme.body
        threshold.setAccessibilityLabel(String(localized: "Stale branch threshold"))
        threshold.target = self
        threshold.action = #selector(manualRefresh)
        let thresholdLabel = Deck.caption(String(localized: "Stale after"))
        let thresholdGroup = Deck.hstack([thresholdLabel, threshold], spacing: 6)
        page.headerTrailing.insertArrangedSubview(thresholdGroup, at: 0)
    }

    private func configureFilterStrip() {
        for filter in CleanupFilter.allCases {
            let button = PartsButton(
                [
                    .symbol(filter.symbolName, color: Theme.secondaryText, size: 11),
                    .text(filter.title, font: Theme.body, color: Theme.secondaryText),
                ],
                background: .hover, accessibility: filter.title
            ) { [weak self] in
                guard let self else { return }
                presenter.activeFilter = filter
                render()
            }
            button.fixedHeight = 26
            button.horizontalPadding = 9
            button.cornerRadius = 6
            button.setAccessibilityIdentifier("cleanup.filter.\(filter.rawValue)")
            filterButtons[filter] = button
            page.controls.addArrangedSubview(button)
        }
        selectAllButton.fixedHeight = 26
        selectAllButton.setAccessibilityIdentifier("cleanup.selectAll")
        page.controls.addArrangedSubview(Deck.spacer())
        page.controls.addArrangedSubview(selectAllButton)
    }

    private func configureTableAndActions() {
        page.refresh.onClick = { [weak self] in self?.manualRefresh() }
        page.action.onClick = { [weak self] in self?.confirm() }
        page.table.delegate = self
        page.table.dataSource = self
        page.table.selectionHighlightStyle = .regular
        page.table.target = self
        page.table.doubleAction = #selector(doubleClickRow)
        page.table.onSpaceKey = { [weak self] in self?.toggleSelectedRow() }
    }

    @objc private func manualRefresh() { refresh(clearFailures: true) }

    private func refresh(clearFailures: Bool) {
        guard !presenter.isCleaning else { return }
        scan?.cancel()
        let id = presenter.startScan(clearFailures: clearFailures)
        let days = thresholds[max(0, threshold.indexOfSelectedItem)]
        render()
        scan = Task {
            do {
                let report = try await service.scanCleanupCandidates(staleThresholdDays: days)
                try Task.checkCancellation()
                presenter.completeScan(report, id: id)
            } catch {
                if Task.isCancelled { return }
                presenter.failScan(error.localizedDescription, id: id)
            }
            render()
        }
    }

    private func render() {
        rows = presenter.visibleRows()
        updateFilterButtons()
        updateActionControls()
        let empty = emptyStateMessage()
        let emptySymbol = presenter.scanState.errorMessage != nil ? "exclamationmark.triangle" : "checkmark.circle"
        page.feedback(
            presenter.status, emptyMessage: empty, emptySymbol: emptySymbol,
            isError: presenter.hasStatusError || presenter.scanState.errorMessage != nil)
        page.table.reloadData()
    }

    private func updateFilterButtons() {
        for filter in CleanupFilter.allCases {
            guard let button = filterButtons[filter] else { continue }
            let isSelected = presenter.activeFilter == filter
            let count = presenter.filterCount(for: filter)
            let textColor = isSelected ? Theme.text : Theme.secondaryText
            let iconColor = isSelected ? Theme.working : Theme.secondaryText
            button.parts = [
                .symbol(filter.symbolName, color: iconColor, size: 11),
                .text(filter.title, font: isSelected ? Theme.bodyEmphasis : Theme.body, color: textColor),
                .badge("\(count)", fill: isSelected ? Theme.window : Theme.control, color: textColor),
            ]
            button.background = isSelected ? .selected : .hover
            button.isEnabled = !presenter.isBusy
            button.setAccessibilityValue(isSelected ? String(localized: "selected") : nil)
        }
    }

    private func updateActionControls() {
        let busy = presenter.isBusy
        let allSelected = presenter.isAllVisibleSelected
        let toggleTitle = allSelected ? String(localized: "Deselect All") : String(localized: "Select All")
        let toggleSymbol = allSelected ? "xmark.circle" : "checkmark.circle"
        selectAllButton.parts = [
            .symbol(toggleSymbol, color: Theme.secondaryText, size: 11.5),
            .text(toggleTitle, font: Theme.body, color: Theme.text),
        ]
        selectAllButton.setAccessibilityLabel(toggleTitle)
        selectAllButton.isEnabled = !rows.isEmpty && !busy
        page.setActionTitle(presenter.actionButtonTitle, symbol: "trash")
        page.action.isEnabled = presenter.selectionCount > 0 && !busy
        page.refresh.isEnabled = !busy
        threshold.isEnabled = !busy
        page.summary.stringValue = presenter.selectionText
        updateDefaultBranchSubtitle()
    }

    private func updateDefaultBranchSubtitle() {
        guard let base = presenter.scanState.report?.defaultBranch else { return }
        page.subtitle.stringValue = String(localized: "Comparing against \(base) · Space toggles selection")
    }

    private func emptyStateMessage() -> String {
        guard rows.isEmpty else { return "" }
        if let error = presenter.scanState.errorMessage { return error }
        return presenter.scanState.isScanning
            ? String(localized: "Scanning repository…")
            : String(localized: "No cleanup candidates match this filter.")
    }

    func numberOfRows(in _: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow _: Int) -> NSTableRowView? {
        DeckTableRowView.reused(in: tableView, id: Self.rowID)
    }

    func tableView(_: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        let item = rows[row]
        let check = makeCheckbox(for: item)
        let icon = StorageStyle.iconBadge(
            item.isWorktree ? Deck.worktreeSymbol : "arrow.triangle.branch", tint: rowIconTint(item), boxSize: 26,
            symbolSize: 12, cornerRadius: 6)
        let title = Deck.label(item.displayTitle, font: Theme.bodyEmphasis, color: Theme.text)
        title.lineBreakMode = .byTruncatingMiddle
        let detail = Deck.label(
            item.detailText, font: Theme.caption, color: item.isFailure ? Theme.failure : Theme.secondaryText)
        detail.lineBreakMode = .byTruncatingMiddle
        let textColumn = Deck.vstack([title, detail], spacing: 2)
        textColumn.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = Deck.hstack([check, icon, textColumn, Deck.spacer()], spacing: 10)
        for badge in item.badges {
            stack.addArrangedSubview(
                WorkflowPageView.pill(badge.title, symbol: badge.symbolName, color: badgeColor(badge)))
        }
        stack.addArrangedSubview(makeAgeLabel(item.ageText))
        let container = WorkflowPageView.wrapRow(
            stack, insets: NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 14), divider: row < rows.count - 1)
        container.toolTip = [item.title, item.warning].compactMap { $0 }.joined(separator: "\n")
        return container
    }

    private func makeCheckbox(for item: CleanupRowItem) -> NSButton {
        let check = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleRow))
        check.controlSize = .small
        check.identifier = .init(item.id)
        check.setAccessibilityLabel(item.displayTitle)
        check.state = item.isSelected ? .on : .off
        check.isEnabled = !presenter.isBusy
        return check
    }

    private func makeAgeLabel(_ text: String) -> NSTextField {
        let label = Deck.label(
            text, font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular), color: Theme.tertiaryText)
        label.alignment = .right
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        return label
    }

    private func rowIconTint(_ item: CleanupRowItem) -> NSColor {
        if item.isFailure || item.badges.contains(.dirtyWarning) { return Theme.failure }
        if item.isWorktree { return item.badges.contains(.prunable) ? Theme.merged : Theme.running }
        if item.badges.contains(.merged) { return Theme.success }
        if item.badges.contains(.unmergedWarning) { return Theme.needsInputText }
        return Theme.working
    }

    private func badgeColor(_ badge: CleanupBadge) -> NSColor {
        switch badge {
        case .dirtyWarning, .failed: Theme.failure
        case .unmergedWarning, .stale: Theme.needsInputText
        case .merged: Theme.success
        case .goneUpstream: Theme.running
        case .prunable: Theme.merged
        }
    }

    private func toggleSelectedRow() {
        let index = page.table.selectedRow
        guard rows.indices.contains(index) else { return }
        presenter.toggleSelection(id: rows[index].id)
        render()
        page.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    }

    @objc private func doubleClickRow() {
        let index = page.table.clickedRow
        guard rows.indices.contains(index) else { return }
        presenter.toggleSelection(id: rows[index].id)
        render()
        page.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    }

    @objc private func toggleRow(_ sender: NSButton) {
        if let id = sender.identifier?.rawValue { presenter.toggleSelection(id: id) }
        render()
    }

    private func toggleAll() {
        if presenter.isAllVisibleSelected { presenter.deselectAllVisible() } else { presenter.selectAllVisible() }
        render()
    }

    private func confirm() {
        guard !presenter.isBusy, presenter.selectionCount > 0, let window = view.window else { return }
        let alert = DestructiveConfirmation(
            message: String(localized: "Clean selected branches and worktrees?"),
            detail: String(localized: "Review every item before removing it."),
            action: String(localized: "Clean Selected")
        ).alert()
        WorkflowPageView.review(alert, detail: presenter.confirmationSummary())
        alert.showsSuppressionButton = presenter.includesUnmerged
        alert.suppressionButton?.title = String(localized: "Allow deletion of unmerged branches")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let allow = presenter.includesUnmerged && alert.suppressionButton?.state == .on
            run(presenter.buildBatchSelection(allowUnmergedBranchDelete: allow))
        }
    }

    private func run(_ selection: CleanupBatchSelection) {
        presenter.startCleanup()
        render()
        Task {
            do {
                let result = try await service.executeCleanup(selection)
                presenter.completeCleanup(result)
                onDidMutate()
                if !result.failures.isEmpty, let window = view.window, window.isVisible {
                    showPartialFailures(result, on: window)
                }
            } catch { presenter.failCleanup(error.localizedDescription) }
            refresh(clearFailures: false)
        }
    }

    private func showPartialFailures(_ result: CleanupBatchResult, on window: NSWindow) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Some items could not be cleaned.")
        alert.informativeText = presenter.status
        WorkflowPageView.review(alert, detail: CleanupAssistantPresenter.failureDetails(for: result))
        alert.addButton(withTitle: String(localized: "OK"))
        alert.beginSheetModal(for: window) { _ in }
    }
}
