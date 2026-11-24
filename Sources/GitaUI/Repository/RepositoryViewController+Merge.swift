import AppKit
import GitaCore

/// Merge conflicts in Local Changes: the selected conflict opens in the merge editor over the code pane, Save & Stage
/// moves on to the next one, and the operation bar resolves every simple conflict at once.
extension RepositoryViewController {
    func wireMerge() {
        merge.view.isHidden = true
        merge.onSaved = { [weak self] path in self?.selectConflict(after: path) }
        merge.onReopen = { [weak self] path in self?.reopenConflict(path: path) }
        operationBar.onResolveSimple = { [weak self] in self?.resolveSimpleConflicts() }
        simpleScan.onChange = { [weak self] in self?.applyOperationBar() }
    }

    /// The conflict selected in Local Changes, if any.
    private var selectedConflict: FileChange? {
        guard model.section == .changes, let file = model.selectedFile, file.isConflict else { return nil }
        return file
    }

    /// Follows the selection: the merge editor shows the selected conflict, or hides.
    func syncMergeEditor() {
        selectPendingConflict()
        simpleScan.update(
            conflicts: (model.snapshot?.changes ?? []).filter(\.isConflict).map(\.path), service: model.service)
        let file = selectedConflict
        if file != nil {
            if merge.view.superview !== codePane { Style.fill(merge.view, in: codePane) }
        } else {
            merge.view.removeFromSuperview()
        }
        merge.show(file, model: model)
        merge.view.isHidden = file == nil
    }

    /// A reopened conflict is selected once the snapshot lists it again.
    private func selectPendingConflict() {
        guard let path = pendingConflictPath,
            let file = model.snapshot?.changes.first(where: { $0.path == path && $0.isConflict })
        else { return }
        pendingConflictPath = nil
        DispatchQueue.main.async { [weak self] in self?.chooseChange(file, staged: false) }
    }

    /// Double-click or Return on a conflict: the cursor goes to the result.
    func focusMergeResult() {
        guard !merge.view.isHidden else { return }
        view.window?.makeFirstResponder(merge.view.resultPane)
    }

    /// After Save & Stage: the next conflict in the list (wrapping), if any is left.
    func selectConflict(after path: String) {
        let conflicts = (model.snapshot?.changes ?? []).filter(\.isConflict)
        let index = conflicts.firstIndex { $0.path == path }
        let rest = index.map { Array(conflicts[($0 + 1)...] + conflicts[..<$0]) } ?? conflicts
        guard let next = rest.first(where: { $0.path != path }) else { return }
        chooseChange(next, staged: false)
    }

    /// The file menu's Use Current / Use Incoming: the whole file from one side, without opening it.
    func resolveConflict(_ file: FileChange, side: MergeSide) {
        guard let service = model.service, !model.isMutating else { return }
        let model = model
        Task {
            do {
                let document = try await service.conflict(path: file.path)
                try await model.resolveConflict(document, resolution: side == .ours ? .ours : .theirs, using: service)
            } catch {
                model.showError(String(localized: "Cannot resolve the conflict"), error.localizedDescription)
            }
        }
    }

    func reopenConflict(_ file: FileChange) { reopenConflict(path: file.path) }

    /// Brings back a resolved file's conflict and selects it.
    func reopenConflict(path: String) {
        guard let operation = model.snapshot?.operation else { return }
        model.perform(
            String(localized: "Reopen conflict"),
            onSuccess: { [weak self] in
                guard let self else { return }
                self.pendingConflictPath = path
                self.model.section = .changes
            },
            operation: { try await $0.reopenConflict(path: path, expected: operation) })
    }

    /// Resolve Simple Conflicts: every conflicted file whose changes Gitā can merge on its own (non-conflicting
    /// changes and simple conflicts only) is merged and staged; the others stay for the user.
    func resolveSimpleConflicts() {
        guard let service = model.service, !model.isMutating else { return }
        let paths = (model.snapshot?.changes ?? []).filter(\.isConflict).map(\.path)
        let model = model
        let title = String(localized: "Resolve simple conflicts")
        Task {
            var resolved = 0
            do {
                let operation = try await service.operationState()
                for path in paths {
                    let document = try await service.conflict(path: path)
                    guard let text = MergeEditorState.simpleResult(document) else { continue }
                    guard try await service.operationState() == operation else {
                        throw StaleStateError.operationChanged
                    }
                    try await model.resolveConflict(document, resolution: .edited(text), using: service)
                    resolved += 1
                }
                model.setStatus(MergeEditorState.simpleSummary(resolved: resolved, of: paths.count))
            } catch {
                model.showError(title, error.localizedDescription)
            }
        }
    }
}
