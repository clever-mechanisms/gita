import AppKit
import GitaCore

/// Runs the merge editor for the selected conflict: reads it (and checks the operation stayed the same), keeps
/// what was done to each file while another one is shown, and writes the result with Save & Stage.
@MainActor
final class MergeEditorController {
    let view = MergeEditorView()
    private(set) var state = MergeEditorState()
    /// Work on files the user moved away from, kept while the conflict is unchanged.
    private var drafts: [String: MergeEditorState.Editing] = [:]
    private let reads = LatestTask()
    private let previews = LatestTask()
    private var words = true
    private weak var model: AppModel?
    /// Save & Stage wrote this path.
    var onSaved: ((String) -> Void)?
    /// Reopen was asked for this path.
    var onReopen: ((String) -> Void)?

    init() {
        view.onAction = { [weak self] in self?.perform($0) }
        view.onSave = { [weak self] in self?.save() }
        view.onReload = { [weak self] in self?.reload() }
        view.onReopen = { [weak self] in
            guard let self, let path = self.state.path else { return }
            self.onReopen?(path)
        }
        view.onWords = { [weak self] on in
            self?.words = on
            self?.render()
        }
    }

    /// Shows the conflict `file` (nil: none). The conflict is read again only for another path.
    func show(_ file: FileChange?, model: AppModel) {
        self.model = model
        guard let file else {
            if state.path != nil { leave() }
            render()
            return
        }
        guard file.path != state.path else {
            render()
            return
        }
        leave()
        load(file.path)
    }

    /// Reload: the conflict as Git has it now; work on it is dropped.
    func reload() {
        guard let path = state.path, !state.isBusy else { return }
        drafts[path] = nil
        load(path)
    }

    func perform(_ action: MergeAction) {
        guard model?.isMutating != true, state.perform(action) else { return }
        render()
    }

    func save() {
        guard let model, let service = model.service, !model.isMutating, let resolution = state.resolution() else {
            return
        }
        guard case .success(let chosen) = resolution else {
            if case .failure(let error) = resolution { state.report(error.localizedDescription) }
            render()
            return
        }
        guard let editing = state.beginSaving() else { return }
        render()
        Task { [weak self, weak model] in
            do {
                guard let model else { throw CancellationError() }
                guard try await service.operationState() == editing.operation else {
                    throw StaleStateError.operationChanged
                }
                try await model.resolveConflict(editing.document, resolution: chosen, using: service)
                self?.drafts[editing.document.path] = nil
                self?.state.saved()
                self?.render()
                self?.onSaved?(editing.document.path)
            } catch {
                self?.state.saveFailed(error.localizedDescription)
                self?.render()
            }
        }
    }

    /// The tab closes: reads stop; a write already started finishes on its own.
    func cancel() {
        reads.cancel()
        previews.cancel()
    }

    func render() {
        view.apply(MergeEditorDisplay(state: state, isMutating: model?.isMutating == true, words: words))
    }

    /// Keeps the work on the file being left, and closes it.
    private func leave() {
        reads.cancel()
        previews.cancel()
        if let editing = state.editing, case .editing = state.phase { drafts[editing.document.path] = editing }
        state.close()
    }

    private func load(_ path: String) {
        guard let service = model?.service else { return }
        state.load(path: path)
        reads.run {
            let operation = try await service.operationState()
            let document = try await service.conflict(path: path)
            guard try await service.operationState() == operation else { throw StaleStateError.operationChanged }
            return (operation, document)
        } then: { [weak self] result in
            guard let self, self.state.path == path else { return }
            switch result {
            case .success(let (operation, document)):
                let draft = self.drafts[path]
                self.drafts[path] = nil
                if let draft, draft.document.fingerprint == document.fingerprint, draft.operation == operation {
                    self.state.loaded(draft)
                } else {
                    self.state.loaded(MergeEditorState.Editing(document: document, operation: operation))
                }
            case .failure(let error): self.state.loadFailed(error.localizedDescription)
            }
            self.render()
            self.loadPreviews()
        }
        render()
    }

    /// The bytes of each side still to be read (an image to show), for the conflict shown now.
    private func loadPreviews() {
        guard let editing = state.editing, let service = model?.service else { return }
        let document = editing.document
        let wanted = editing.unreadPreviews
        guard !wanted.isEmpty else { return }
        previews.run {
            var found: [MergeSide: MergePreview] = [:]
            for (side, version) in wanted {
                do {
                    found[side] = .data(try await service.conflictVersionData(version))
                } catch {
                    found[side] = .note(error.localizedDescription)
                }
            }
            return found
        } then: { [weak self] result in
            guard let self, case .success(let found) = result else { return }
            for (side, preview) in found {
                self.state.showPreview(preview, side: side, fingerprint: document.fingerprint)
            }
            self.render()
        }
    }
}
