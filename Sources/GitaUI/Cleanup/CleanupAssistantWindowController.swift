import AppKit
import GitaCore

@MainActor
final class CleanupAssistantWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource,
    NSTableViewDelegate
{
    private let service: GitService
    private let onDidMutate: () -> Void
    private let content = WorkflowWindowContent(
        title: String(localized: "Branch & Worktree Cleanup"), actionTitle: String(localized: "Clean Selected…"))
    private var presenter = CleanupAssistantPresenter()
    private var rows: [CleanupRowItem] = []
    private var scan: Task<Void, Never>?
    private let thresholds = [14, 30, 60, 90]
    private let threshold = NSPopUpButton()
    private lazy var filter = ActionSegmentedControl(labels: CleanupFilter.allCases.map(\.title)) { [weak self] index in
        guard let self, CleanupFilter.allCases.indices.contains(index) else { return }
        presenter.activeFilter = CleanupFilter.allCases[index]
        render()
    }
    private lazy var selectAll = NSButton(
        checkboxWithTitle: String(localized: "Select All Visible"), target: self, action: #selector(toggleAll))

    init(gitService: GitService, onDidMutate: @escaping () -> Void = {}) {
        service = gitService
        self.onDidMutate = onDidMutate
        super.init(window: content.window)
        window?.delegate = self
        content.subtitle.stringValue = String(localized: "Review merged branches and idle worktrees.")
        for days in thresholds { threshold.addItem(withTitle: String(localized: "\(days) days")) }
        threshold.selectItem(at: 1)
        threshold.setAccessibilityLabel(String(localized: "Stale branch threshold"))
        threshold.target = self
        threshold.action = #selector(manualRefresh)
        content.header.insertArrangedSubview(threshold, at: 2)
        content.controls.addArrangedSubview(filter)
        content.controls.addArrangedSubview(SheetChrome.spacer())
        content.controls.addArrangedSubview(selectAll)
        content.refresh.target = self
        content.refresh.action = #selector(manualRefresh)
        content.action.target = self
        content.action.action = #selector(confirm)
        content.table.delegate = self
        content.table.dataSource = self
        content.table.selectionHighlightStyle = .regular
        content.table.onSpaceKey = { [weak self] in self?.toggleSelectedRow() }
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
        AuxiliaryWindowActivation.closing(window)
    }

    @objc private func manualRefresh() { refresh(clearFailures: true) }

    private func refresh(clearFailures: Bool) {
        guard !presenter.isCleaning else { return }
        scan?.cancel()
        let id = presenter.startScan(clearFailures: clearFailures)
        let days = thresholds[threshold.indexOfSelectedItem]
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
        updateFilterSegments()
        updateActionControls()
        let empty = emptyStateMessage()
        content.feedback(
            presenter.status, emptyMessage: empty, isError: presenter.hasStatusError)
        content.table.reloadData()
    }

    private func updateFilterSegments() {
        for (index, item) in CleanupFilter.allCases.enumerated() {
            let count = presenter.filterCount(for: item)
            filter.setLabel(String(localized: "\(item.title) (\(count))"), forSegment: index)
        }
        filter.selectedSegment = CleanupFilter.allCases.firstIndex(of: presenter.activeFilter) ?? 0
    }

    private func updateActionControls() {
        let busy = presenter.isBusy
        selectAll.state = presenter.isAllVisibleSelected ? .on : .off
        selectAll.isEnabled = !rows.isEmpty && !busy
        content.action.isEnabled = presenter.selectionCount > 0 && !busy
        content.refresh.isEnabled = !busy
        threshold.isEnabled = !busy
        content.summary.stringValue = presenter.selectionText
        updateDefaultBranchSubtitle()
    }

    private func updateDefaultBranchSubtitle() {
        guard let base = presenter.scanState.report?.defaultBranch else { return }
        content.subtitle.stringValue = String(localized: "Merged against \(base). Space toggles selection.")
    }

    private func emptyStateMessage() -> String {
        guard rows.isEmpty else { return "" }
        if let error = presenter.scanState.errorMessage { return error }
        return presenter.scanState.isScanning
            ? String(localized: "Scanning repository…")
            : String(localized: "No cleanup candidates match this filter.")
    }

    func numberOfRows(in _: NSTableView) -> Int { rows.count }

    func tableView(_: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        let item = rows[row]
        let check = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleRow))
        check.identifier = .init(item.id)
        check.setAccessibilityLabel(item.title)
        check.state = item.isSelected ? .on : .off
        check.isEnabled = !presenter.isBusy
        let symbol = item.isWorktree ? "folder" : "arrow.triangle.branch"
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = Theme.secondaryText
        let label = item.subtitle.map { "\(item.title) (\($0))" } ?? item.title
        let title = Style.label(label, size: 13)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = Style.stack([check, icon, title, SheetChrome.spacer()])
        row.toolTip = [label, item.warning].compactMap { $0 }.joined(separator: "\n")
        for badge in item.badges {
            row.addArrangedSubview(WorkflowWindowContent.pill(badge.title, color: badgeColor(badge)))
        }
        row.addArrangedSubview(WorkflowWindowContent.pill(item.ageText))
        return row
    }

    private func badgeColor(_ badge: CleanupBadge) -> NSColor {
        switch badge {
        case .dirtyWarning, .failed: Theme.failure
        case .unmergedWarning: Theme.needsInputText
        case .merged, .goneUpstream, .stale, .prunable: Theme.accent
        }
    }

    private func toggleSelectedRow() {
        let index = content.table.selectedRow
        guard rows.indices.contains(index) else { return }
        presenter.toggleSelection(id: rows[index].id)
        render()
        content.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    }

    @objc private func toggleRow(_ sender: NSButton) {
        if let id = sender.identifier?.rawValue { presenter.toggleSelection(id: id) }
        render()
    }
    @objc private func toggleAll() {
        if presenter.isAllVisibleSelected { presenter.deselectAllVisible() } else { presenter.selectAllVisible() }
        render()
    }

    @objc private func confirm() {
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
