import AppKit
import GitaCore

/// Amend Last Commit from Local Changes: the checkbox loads HEAD's message and staged changes against its parent,
/// and Commit rewrites that commit.
extension RepositoryViewController {
    func toggleAmend() {
        if amend.isOn {
            cancelAmend(restoreIndex: true)
            updateCommitActions()
            return
        }
        amendLoad += 1
        let load = amendLoad
        amend = .loading
        updateCommitActions()
        guard let service = model.service else {
            amend = .off
            updateCommitActions()
            return
        }
        Task { [weak self] in await self?.finishAmendLoad(load, service: service) }
    }

    /// The composer's text is the draft, or the amend message while Amend is armed.
    func noteCommitField(_ text: String) {
        if case .armed = amend {
            amend = amend.withMessage(text)
        } else {
            model.setCommitMessage(text)
        }
    }

    func showCommitField() {
        commitFooter.show(message: amend.fieldText ?? model.commitMessage)
    }

    /// Drops Amend when HEAD moved or the repository can no longer take a commit.
    func reconcileAmend() {
        guard amend.invalidated(by: model.snapshot, hasConflicts: model.hasConflicts) else { return }
        cancelAmend(restoreIndex: false)
    }

    func amendArmedCommit(andPush: Bool = false) {
        noteCommitField(commitFooter.message)
        guard case .armed(let source, let message) = amend else { return }
        if andPush, source.isPublished { return }
        let subject = message.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subject.isEmpty else {
            model.showError(String(localized: "Could not amend"), String(localized: "Enter a commit message."))
            return
        }
        guard model.snapshot?.head == source.id, model.snapshot?.operation == nil, !model.hasConflicts else {
            model.showError(
                String(localized: "Could not amend"),
                String(localized: "The last commit changed. Refresh before amending it."))
            return
        }
        let full = CommitMessageText.preparedForCommit(message.full)
        if source.isPublished {
            confirmPublishedAmend { [weak self] in self?.performAmend(source, message: full, andPush: false) }
        } else {
            performAmend(source, message: full, andPush: andPush)
        }
    }

    private func finishAmendLoad(_ load: Int, service: GitService) async {
        do {
            let source = try await service.amendCommit()
            guard load == amendLoad, model.service === service else { return }
            guard let source else {
                amend = .off
                model.showError(
                    String(localized: "Could not amend"), String(localized: "There is no commit to amend."))
                updateCommitActions()
                return
            }
            let staged = try await service.stagedChanges(against: source.baseTree)
            guard load == amendLoad, model.service === service,
                model.snapshot?.head == source.id, model.snapshot?.operation == nil, !model.hasConflicts
            else {
                if load == amendLoad { amend = .off }
                updateCommitActions()
                return
            }
            let message = AmendMessage(source.message)
            amend = .armed(source, message)
            amendUnstagedPaths = []
            model.setAmendStaging(base: source.baseTree, head: source.id, files: staged)
            commitFooter.show(message: message.full)
            refreshAmendChangesView(selectStagedIfEmpty: true)
            updateCommitActions()
        } catch {
            guard load == amendLoad, model.service === service else { return }
            amend = .off
            model.showError(String(localized: "Could not amend"), error.localizedDescription)
            updateCommitActions()
        }
    }

    private func cancelAmend(restoreIndex: Bool) {
        guard amend.isOn else { return }
        let paths = restoreIndex ? amendUnstagedPaths.sorted() : []
        amendUnstagedPaths = []
        amendLoad += 1
        amend = .off
        model.clearAmendStaging()
        commitFooter.show(message: model.commitMessage)
        if !paths.isEmpty {
            model.perform(String(localized: "Restore staged")) { try await $0.restoreStagedToHead(paths: paths) }
        } else {
            refreshAmendChangesView(selectStagedIfEmpty: false)
        }
    }

    private func refreshAmendChangesView(selectStagedIfEmpty: Bool) {
        guard model.section == .changes else { return }
        let changes = model.snapshot?.changes ?? []
        renderedChanges = changes
        renderedAmendStaging = model.amendStaging
        hasRenderedChanges = true
        filePane.showChanges(changes, amendStaging: model.amendStaging)
        if selectStagedIfEmpty, model.selectedFile == nil, !model.amendStaging.files.isEmpty {
            model.staged = true
            model.showChanges()
        } else if model.staged {
            model.showChanges(preferredPath: model.selectedFile?.path, refreshing: true)
        }
        updateCodePane()
    }

    private func performAmend(_ source: GitService.AmendCommit, message: String, andPush: Bool = false) {
        let expectedService = model.service
        model.perform(
            String(localized: "Amend"),
            onSuccess: { [weak self] in
                guard let self else { return }
                self.amendLoad += 1
                self.amend = .off
                self.amendUnstagedPaths = []
                self.model.clearAmendStaging()
                self.commitFooter.show(message: self.model.commitMessage)
                self.updateCommitActions()
                if andPush, let expectedService {
                    DispatchQueue.main.async { [weak self] in self?.pushAfterCommit(using: expectedService) }
                }
            }, operation: { try await $0.commit(message: message, amending: source.id) })
    }

    private func confirmPublishedAmend(_ commit: @escaping @MainActor () -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Amend a commit that is already on the upstream?")
        alert.informativeText = String(
            localized: """
                This commit is already on the upstream branch. Amending it rewrites history and needs a force push.
                """)
        let amend = alert.addButton(withTitle: String(localized: "Amend"))
        amend.hasDestructiveAction = true
        amend.keyEquivalent = ""
        alert.addButton(withTitle: String(localized: "Cancel")).keyEquivalent = "\u{1b}"
        model.alerts.confirm(alert, on: view.window, onConfirm: commit)
    }
}
