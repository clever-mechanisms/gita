import AppKit
import GitaCore

@MainActor
final class BranchStackWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource,
    NSTableViewDelegate
{
    private static let rowID = NSUserInterfaceItemIdentifier("stack.table.row")
    private let service: GitService
    private let base: String?
    private let onDidMutate: () -> Void
    private let content: WorkflowWindowContent
    private var presenter = BranchStackPresenter()
    private var rows: [StackTreeRow] = []
    private var readTask: Task<Void, Never>?
    private var mutationTask: Task<Void, Never>?

    init(
        gitService: GitService, baseBranch: String? = nil, repositoryName: String? = nil,
        onDidMutate: @escaping () -> Void = {}
    ) {
        service = gitService
        base = baseBranch
        self.onDidMutate = onDidMutate
        content = WorkflowWindowContent(
            title: String(localized: "Stacked Branches"), repositoryName: repositoryName,
            symbol: "square.stack.3d.up", actionTitle: String(localized: "Restack Chain…"),
            actionSymbol: "arrow.triangle.2.circlepath")
        super.init(window: content.window)
        window?.delegate = self
        content.showsControls = false
        content.refresh.onClick = { [weak self] in self?.refresh() }
        content.action.onClick = { [weak self] in self?.review() }
        content.table.delegate = self
        content.table.dataSource = self
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    func present() {
        AuxiliaryWindowActivation.show(content.window)
        refresh()
    }
    func windowShouldClose(_: NSWindow) -> Bool { !presenter.isRestacking && mutationTask == nil }
    func windowWillClose(_: Notification) {
        readTask?.cancel()
        if !presenter.isRestacking { presenter.cancelPreview() }
        content.stopObservingTheme()
        AuxiliaryWindowActivation.closing(window)
    }

    private func refresh() {
        guard !presenter.isRestacking else { return }
        readTask?.cancel()
        let id = presenter.startLoading()
        render()
        readTask = Task {
            do {
                let values = try await service.detectBranchStacks(baseBranch: base)
                try Task.checkCancellation()
                presenter.loaded(values, id: id)
            } catch {
                if Task.isCancelled { return }
                presenter.fail(error.localizedDescription)
            }
            render()
        }
    }

    private func render() {
        rows = presenter.rows()
        content.table.reloadData()
        if let index = rows.firstIndex(where: { $0.stackID == presenter.selectedStackID }) {
            content.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else {
            content.table.deselectAll(nil)
        }
        content.refresh.isEnabled = !presenter.isBusy
        let baseName = presenter.selected?.baseBranch ?? base
        content.subtitle.stringValue =
            baseName.map { String(localized: "Base branch: \($0)") }
            ?? String(localized: "Chained local feature branches")
        let empty = presenter.status.isEmpty ? String(localized: "No stacked branches found.") : presenter.status
        content.feedback(
            presenter.status, emptyMessage: rows.isEmpty ? empty : "",
            emptySymbol: presenter.hasError ? "exclamationmark.triangle" : "square.stack.3d.up",
            isError: presenter.hasError)
        bindSelection()
    }

    private func bindSelection() {
        content.summary.stringValue =
            presenter.selected.map { String(localized: "\($0.baseBranch) → \($0.topBranch)") }
            ?? String(localized: "Select a stack")
        content.action.isEnabled = presenter.canRestack
    }

    func numberOfRows(in _: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow _: Int) -> NSTableRowView? {
        DeckTableRowView.reused(in: tableView, id: Self.rowID)
    }

    func tableViewSelectionDidChange(_: Notification) {
        let index = content.table.selectedRow
        guard rows.indices.contains(index) else { return }
        presenter.selectedStackID = rows[index].stackID
        bindSelection()
    }

    func tableView(_: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        let item = rows[row]
        var leadingViews: [NSView] = []
        if let symbol = item.connectorSymbol {
            let arrow = Deck.icon(symbol, size: 11, weight: .medium, color: Theme.tertiaryText)
            arrow.setAccessibilityElement(false)
            leadingViews.append(arrow)
        }
        let iconTint: NSColor = item.isCurrent ? Theme.checkedOut : (item.depth == 0 ? Theme.accent : Theme.working)
        leadingViews.append(
            StorageStyle.iconBadge(
                "arrow.triangle.branch", tint: iconTint, boxSize: 24, symbolSize: 11, cornerRadius: 6))
        let title = Deck.label(
            item.title, font: item.depth == 0 ? Theme.title : Theme.bodyEmphasis, color: Theme.text)
        var titleViews: [NSView] = [title]
        if item.isCurrent {
            titleViews.append(
                WorkflowWindowContent.pill(
                    String(localized: "Current"), symbol: "checkmark.circle.fill", color: Theme.checkedOut))
        }
        let summary = Deck.caption(item.summary)
        let textColumn = Deck.vstack([Deck.hstack(titleViews, spacing: 6), summary], spacing: 2)
        textColumn.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = Deck.hstack(leadingViews + [textColumn, Deck.spacer()], spacing: 8)
        if item.needsRestack {
            stack.addArrangedSubview(
                WorkflowWindowContent.pill(
                    String(localized: "Needs Restack"), symbol: "exclamationmark.triangle.fill",
                    color: Theme.needsInputText))
        }
        stack.addArrangedSubview(
            WorkflowWindowContent.pill(
                item.counts, color: item.needsRestack ? Theme.needsInputText : Theme.secondaryText)
        )
        let leftInset = 12 + CGFloat(min(item.depth, 10)) * 18
        let container = WorkflowWindowContent.wrapRow(
            stack, insets: NSEdgeInsets(top: 6, left: leftInset, bottom: 6, right: 14), divider: row < rows.count - 1)
        container.toolTip = item.summary
        return container
    }

    private func review() {
        guard presenter.canRestack, let stack = presenter.selected else { return }
        readTask?.cancel()
        _ = presenter.startLoading()
        render()
        readTask = Task {
            do {
                let preview = try await service.previewStackRestack(stack: stack)
                try Task.checkCancellation()
                presenter.preview(preview)
                render()
                confirm(preview)
            } catch {
                if Task.isCancelled { return }
                presenter.fail(error.localizedDescription)
                render()
            }
        }
    }

    private func confirm(_ preview: BranchStackRestackPreview) {
        let blocked = !preview.blockedByWorktreePaths.isEmpty
        let alert = makeConfirmAlert(for: preview, blocked: blocked)
        alert.beginSheetModal(for: content.window) { [weak self] response in
            self?.finishConfirm(preview, blocked: blocked, response: response)
        }
    }

    private func makeConfirmAlert(for preview: BranchStackRestackPreview, blocked: Bool) -> NSAlert {
        let alert = NSAlert()
        alert.messageText =
            blocked
            ? String(localized: "Another worktree is using this stack.")
            : String(localized: "Restack this chain?")
        WorkflowWindowContent.review(alert, detail: BranchStackPresenter.reviewText(preview))
        if !blocked {
            let button = alert.addButton(withTitle: String(localized: "Restack Chain"))
            button.hasDestructiveAction = true
            button.keyEquivalent = ""
        }
        alert.addButton(withTitle: blocked ? String(localized: "Close") : String(localized: "Cancel"))
        return alert
    }

    private func finishConfirm(
        _ preview: BranchStackRestackPreview, blocked: Bool, response: NSApplication.ModalResponse
    ) {
        if !blocked, response == .alertFirstButtonReturn {
            restack(preview)
        } else {
            presenter.cancelPreview()
            render()
        }
    }

    func restack(_ preview: BranchStackRestackPreview) {
        readTask?.cancel()
        presenter.startRestack(preview.stack)
        render()
        mutationTask = Task {
            defer { mutationTask = nil }
            do {
                let result = try await service.restackBranchStack(preview)
                onDidMutate()
                await reload(after: result)
            } catch {
                presenter.fail(error.localizedDescription)
                render()
            }
        }
    }

    private func reload(after result: BranchStackRestackResult) async {
        do {
            let updated = try await service.detectBranchStacks(baseBranch: base)
            presenter.finish(result, stacks: updated)
            render()
        } catch {
            presenter.finish(result, stacks: [])
            render()
            content.feedback(presenter.status, emptyMessage: error.localizedDescription, isError: true)
        }
    }
}
