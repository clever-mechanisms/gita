import AppKit
import GitaCore

/// Streaming File Blame (`§6c`) hosted inside `codePane`.
extension RepositoryViewController {
    var isShowingBlame: Bool {
        blameView.map { !$0.isHidden } ?? false
    }

    var canBlameSelectedFile: Bool {
        model.service != nil
            && (model.selectedTreePath ?? model.selectedFile?.path ?? codePane.diffView.shownPath) != nil
    }

    /// `⌥⌘B` / file menu entry point: blames the currently selected file or tree entry.
    @objc func blameSelectedFile(_: Any? = nil) {
        guard let path = model.selectedTreePath ?? model.selectedFile?.path ?? codePane.diffView.shownPath else {
            return
        }
        let revision: String? =
            if let commit = model.selectedCommit {
                commit.id
            } else if model.section == .changes || model.isReviewingWorkingChanges {
                nil
            } else {
                model.snapshot?.head
            }
        showBlame(path: path, revision: revision)
    }

    func showBlame(path: String, revision: String? = nil) {
        guard let service = model.service else { return }
        blameNavigatedCommitID = nil
        let blameView = ensureBlameView()
        blameView.load.cancel()
        blameView.detailSelectionPath = model.selectedTreePath ?? model.diffPath
        blameView.isHidden = false
        blameView.showLoading(path: path, revision: revision)
        let requestID = UUID()
        let repoGeneration = model.generation
        let task = Task { @MainActor [weak self, weak blameView] in
            guard let self, let blameView else { return }
            do {
                let doc = try await service.blame(path: path, revision: revision) { partial in
                    await MainActor.run {
                        guard self.model.generation == repoGeneration,
                            case .loading(requestID, _) = blameView.load
                        else { return }
                        blameView.showLoading(path: path, revision: revision, partial: partial)
                    }
                }
                guard !Task.isCancelled, self.model.generation == repoGeneration,
                    case .loading(requestID, _) = blameView.load
                else { return }
                blameView.load = .loaded(doc)
                blameView.showLoaded(doc)
            } catch is CancellationError {
                return
            } catch let error as BlameError {
                guard !Task.isCancelled, self.model.generation == repoGeneration,
                    case .loading(requestID, _) = blameView.load
                else { return }
                blameView.load = .failed(error)
                blameView.showFailed(error, path: path, revision: revision)
            } catch {
                guard !Task.isCancelled, self.model.generation == repoGeneration,
                    case .loading(requestID, _) = blameView.load
                else { return }
                let wrapped = BlameError.failed(error.localizedDescription)
                blameView.load = .failed(wrapped)
                blameView.showFailed(wrapped, path: path, revision: revision)
            }
        }
        blameView.load = .loading(requestID, task)
    }

    func closeBlame() {
        blameNavigatedCommitID = nil
        guard isShowingBlame, let blameView else { return }
        blameView.load.cancel()
        blameView.isHidden = true
    }

    func closeBlameIfFileSwitched(to path: String?) {
        guard isShowingBlame, let blameView, let path else { return }
        if let kept = blameNavigatedCommitID, model.selectedCommit?.id == kept {
            blameView.detailSelectionPath = path
            if !model.isDiffLoading { blameNavigatedCommitID = nil }
            return
        }
        guard let previousPath = blameView.detailSelectionPath else {
            blameView.detailSelectionPath = path
            return
        }
        guard previousPath != path else { return }
        blameView.detailSelectionPath = path
        if blameView.currentPath != path { closeBlame() }
    }

    private func ensureBlameView() -> BlameView {
        if let existing = blameView { return existing }
        let view = BlameView()
        view.onSelectCommit = { [weak self] commitID in
            guard let self else { return }
            self.blameNavigatedCommitID = commitID
            if self.model.section != .history { self.model.section = .history }
            self.selectCommit(id: commitID)
        }
        view.onBlamePrior = { [weak self] commit, path in
            self?.showBlame(path: path, revision: commit)
        }
        view.onShowLineHistory = { [weak self] range in self?.openLineHistory(range: range) }
        view.onCopyPermalink = { [weak self] path, revision, lines in
            self?.copyFilePermalink(path: path, revision: revision, lines: lines)
        }
        view.onClose = { [weak self] in self?.closeBlame() }
        Style.fill(view, in: codePane)
        view.isHidden = true
        blameView = view
        return view
    }
}
