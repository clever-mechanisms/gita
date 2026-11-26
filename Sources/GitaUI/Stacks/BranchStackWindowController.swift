import AppKit
import GitaCore

@MainActor
final class BranchStackWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource,
    NSTableViewDelegate
{
    private let service: GitService
    private let base: String?
    private let onDidMutate: () -> Void
    private let content = WorkflowWindowContent(
        title: String(localized: "Stacked Branches"), actionTitle: String(localized: "Restack Chain…"))
    private var presenter = BranchStackPresenter()
    private var rows: [StackTreeRow] = []
    private var readTask: Task<Void, Never>?
    private var mutationTask: Task<Void, Never>?

    init(gitService: GitService, baseBranch: String? = nil, onDidMutate: @escaping () -> Void = {}) {
        service = gitService
        base = baseBranch
        self.onDidMutate = onDidMutate
        super.init(window: content.window)
        window?.delegate = self
        content.controls.isHidden = true
        content.refresh.target = self
        content.refresh.action = #selector(refresh)
        content.action.target = self
        content.action.action = #selector(review)
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
        AuxiliaryWindowActivation.closing(window)
    }

    @objc private func refresh() {
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
            ?? String(localized: "Local branch ancestry")
        let empty = presenter.status.isEmpty ? String(localized: "No stacked branches found.") : presenter.status
        content.feedback(presenter.status, emptyMessage: rows.isEmpty ? empty : "", isError: presenter.hasError)
        bindSelection()
    }

    private func bindSelection() {
        content.summary.stringValue =
            presenter.selected.map { String(localized: "\($0.baseBranch) → \($0.topBranch)") }
            ?? String(localized: "Select a stack")
        content.action.isEnabled = presenter.canRestack
    }

    func numberOfRows(in _: NSTableView) -> Int { rows.count }

    func tableViewSelectionDidChange(_: Notification) {
        let index = content.table.selectedRow
        guard rows.indices.contains(index) else { return }
        presenter.selectedStackID = rows[index].stackID
        bindSelection()
    }

    func tableView(_: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        let item = rows[row]
        let title = Style.label(item.title, size: 13, weight: item.depth == 0 ? .bold : .medium)
        let summary = Style.label(item.summary, size: 11, color: Theme.secondaryText)
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = Style.stack([Style.label(item.connector, color: Theme.tertiaryText), title])
        row.edgeInsets.left = CGFloat(min(item.depth, 12)) * 14
        if item.isCurrent {
            row.addArrangedSubview(WorkflowWindowContent.pill(String(localized: "Current"), color: Theme.checkedOut))
        }
        row.addArrangedSubview(summary)
        row.addArrangedSubview(SheetChrome.spacer())
        if item.needsRestack {
            row.addArrangedSubview(
                WorkflowWindowContent.pill(String(localized: "Needs Restack"), color: Theme.needsInputText))
        }
        row.addArrangedSubview(WorkflowWindowContent.pill(item.counts))
        row.toolTip = item.summary
        return row
    }

    @objc private func review() {
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
