import AppKit
import GitaCore

@MainActor
final class CleanupAssistantWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource,
    NSTableViewDelegate
{
    private static let rowID = NSUserInterfaceItemIdentifier("cleanup.table.row")
    private let service: GitService
    private let onDidMutate: () -> Void
    private let content: WorkflowWindowContent
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

    init(gitService: GitService, repositoryName: String? = nil, onDidMutate: @escaping () -> Void = {}) {
        service = gitService
        self.onDidMutate = onDidMutate
        content = WorkflowWindowContent(
            title: String(localized: "Branch & Worktree Cleanup"), repositoryName: repositoryName,
            symbol: "wand.and.stars", actionTitle: String(localized: "Clean Selected…"), actionSymbol: "trash")
        super.init(window: content.window)
        window?.delegate = self
        content.subtitle.stringValue = String(localized: "Review merged branches, gone upstreams, and idle worktrees.")
        configureHeaderControls()
        configureFilterStrip()
        configureTableAndActions()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    func present() {
        AuxiliaryWindowActivation.show(content.window)
        refresh(clearFailures: true)
    }

    func windowShouldClose(_: NSWindow) -> Bool { !presenter.isCleaning }

    func windowWillClose(_: Notification) {
        scan?.cancel()
        content.stopObservingTheme()
        AuxiliaryWindowActivation.closing(window)
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
        content.headerTrailing.insertArrangedSubview(thresholdGroup, at: 0)
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
            content.controls.addArrangedSubview(button)
        }
        selectAllButton.fixedHeight = 26
        selectAllButton.setAccessibilityIdentifier("cleanup.selectAll")
        content.controls.addArrangedSubview(Deck.spacer())
        content.controls.addArrangedSubview(selectAllButton)
    }

    private func configureTableAndActions() {
        content.refresh.onClick = { [weak self] in self?.manualRefresh() }
        content.action.onClick = { [weak self] in self?.confirm() }
        content.table.delegate = self
        content.table.dataSource = self
        content.table.selectionHighlightStyle = .regular
        content.table.target = self
        content.table.doubleAction = #selector(doubleClickRow)
        content.table.onSpaceKey = { [weak self] in self?.toggleSelectedRow() }
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
        content.feedback(
            presenter.status, emptyMessage: empty, emptySymbol: emptySymbol,
            isError: presenter.hasStatusError || presenter.scanState.errorMessage != nil)
        content.table.reloadData()
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
        content.setActionTitle(presenter.actionButtonTitle, symbol: "trash")
        content.action.isEnabled = presenter.selectionCount > 0 && !busy
        content.refresh.isEnabled = !busy
        threshold.isEnabled = !busy
        content.summary.stringValue = presenter.selectionText
        updateDefaultBranchSubtitle()
    }

    private func updateDefaultBranchSubtitle() {
        guard let base = presenter.scanState.report?.defaultBranch else { return }
        content.subtitle.stringValue = String(localized: "Comparing against \(base) · Space toggles selection")
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
                WorkflowWindowContent.pill(badge.title, symbol: badge.symbolName, color: badgeColor(badge)))
        }
        stack.addArrangedSubview(makeAgeLabel(item.ageText))
        let container = WorkflowWindowContent.wrapRow(
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
        let index = content.table.selectedRow
        guard rows.indices.contains(index) else { return }
        presenter.toggleSelection(id: rows[index].id)
        render()
        content.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    }

    @objc private func doubleClickRow() {
        let index = content.table.clickedRow
        guard rows.indices.contains(index) else { return }
        presenter.toggleSelection(id: rows[index].id)
        render()
        content.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
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
        guard !presenter.isBusy, presenter.selectionCount > 0 else { return }
        let alert = DestructiveConfirmation(
            message: String(localized: "Clean selected branches and worktrees?"),
            detail: String(localized: "Review every item before removing it."),
            action: String(localized: "Clean Selected")
        ).alert()
        WorkflowWindowContent.review(alert, detail: presenter.confirmationSummary())
        alert.showsSuppressionButton = presenter.includesUnmerged
        alert.suppressionButton?.title = String(localized: "Allow deletion of unmerged branches")
        alert.beginSheetModal(for: content.window) { [weak self] response in
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
                if !result.failures.isEmpty, content.window.isVisible { showPartialFailures(result) }
            } catch { presenter.failCleanup(error.localizedDescription) }
            refresh(clearFailures: false)
        }
    }

    private func showPartialFailures(_ result: CleanupBatchResult) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Some items could not be cleaned.")
        alert.informativeText = presenter.status
        WorkflowWindowContent.review(alert, detail: CleanupAssistantPresenter.failureDetails(for: result))
        alert.addButton(withTitle: String(localized: "OK"))
        alert.beginSheetModal(for: content.window) { _ in }
    }
}
