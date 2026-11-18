import AppKit
import GitaCore

/// Local Changes: choosing, staging and unstaging files, and the commit footer.
extension RepositoryViewController {
    func wireFileLists() {
        filePane.isMutating = { [weak self] in self?.model.isMutating ?? false }
        filePane.onStage = { [weak self] files, staged in self?.setStaged(files, staged) }
        filePane.commitFiles.onSelect = { [weak self] file in self?.model.selectFile(file) }
        filePane.commitFiles.menuProvider = { [weak self] files in self?.commitFileMenu(files) }
        for (section, staged) in [(filePane.unstaged, false), (filePane.staged, true)] {
            let list = section.list
            list.onSelect = { [weak self] file in self?.chooseChange(file, staged: staged) }
            list.onActivate = { [weak self] file in self?.activateChange(file, staged: staged) }
            list.menuProvider = { [weak self] files in self?.changeMenu(files, staged: staged) }
        }
        commitFooter.onBeginEditing = { [weak self] in self?.model.beginEditingCommitMessage() }
        commitFooter.onChange = { [weak self] text in
            self?.noteCommitField(text)
            self?.updateCommitActions()
        }
        commitFooter.onEndEditing = { [weak self] text in
            self?.noteCommitField(text)
            self?.model.endEditingCommitMessage()
            self?.updateCommitActions()
        }
        commitFooter.onStageAll = { [weak self] in self?.stageAllFiles() }
        commitFooter.onCommit = { [weak self] in self?.commitChanges() }
        commitFooter.onAmend = { [weak self] in self?.toggleAmend() }
    }

    /// A file clicked in Unstaged or Staged: that side's diff.
    func chooseChange(_ file: FileChange, staged: Bool) {
        if model.staged != staged {
            model.staged = staged
            model.showChanges(preferredPath: file.path)
        } else if model.selectedFile != file {
            model.selectFile(file)
        }
    }

    /// Double-click (or Return), as in Fork: stages an unstaged file, unstages a staged one, puts the cursor in a
    /// conflict's merge result.
    func activateChange(_ file: FileChange, staged: Bool) {
        if file.isConflict {
            chooseChange(file, staged: false)
            focusMergeResult()
            return
        }
        setStaged([file], !staged)
    }

    func setStaged(_ files: [FileChange], _ staged: Bool) {
        let nonConflicts = files.filter { !$0.isConflict }
        let paths = nonConflicts.map(\.path)
        guard !paths.isEmpty, !model.isMutating else { return }
        if staged {
            if amend.source != nil { amendUnstagedPaths.subtract(paths) }
            model.perform(paths.count == 1 ? String(localized: "Stage file") : String(localized: "Stage files")) {
                try await $0.stage(paths: paths)
            }
        } else {
            let source = amend.source?.baseTree
            if source != nil {
                for file in nonConflicts {
                    amendUnstagedPaths.insert(file.path)
                    if let original = file.originalPath { amendUnstagedPaths.insert(original) }
                }
            }
            model.perform(paths.count == 1 ? String(localized: "Unstage file") : String(localized: "Unstage files")) {
                try await $0.unstage(paths: paths, source: source)
            }
        }
    }

    func stageAllFiles() {
        let paths = model.snapshot?.changes.filter { $0.isUnstaged && !$0.isConflict }.map(\.path) ?? []
        guard !paths.isEmpty else { return }
        if amend.source != nil { amendUnstagedPaths.subtract(paths) }
        model.perform(String(localized: "Stage all")) { try await $0.stage(paths: paths) }
    }

    func updateCommitActions() {
        reconcileAmend()
        let snapshot = model.snapshot
        let source = amend.source
        commitFooter.apply(
            CommitActionsState(
                .init(
                    hasSnapshot: snapshot != nil, hasDraft: model.commitDraft != nil,
                    isDraftCurrent: model.isCommitDraftCurrent, hasOperation: snapshot?.operation != nil,
                    hasConflicts: model.hasConflicts, isMutating: model.isMutating,
                    hasStagedChanges: model.hasStagedChanges,
                    hasUnstagedFiles: snapshot?.changes.contains { $0.isUnstaged && !$0.isConflict } == true,
                    hasHead: snapshot?.head != nil, amendChecked: amend.isOn, amends: source != nil,
                    amendLoading: amend == .loading, amendIsPublished: source?.isPublished == true,
                    amendIsDetached: source?.isDetached == true, message: commitFooter.message)))
        let stash = model.selectedStash != nil
        detailBar.showStash(stash, enabled: !model.isMutating && stash)
    }

    /// Writes the active text input's text to the draft first; false when the field cannot give up editing.
    func flushCommitDraft() -> Bool {
        // Let the input method finish before flushing the field editor's text.
        if commitFooter.isEditing {
            guard view.window?.makeFirstResponder(nil) != false else { return false }
            noteCommitField(commitFooter.message)
        }
        return model.flushCommitDraft()
    }

    func commitChanges() {
        if amend.source != nil {
            amendArmedCommit()
            return
        }
        noteCommitField(commitFooter.message)
        let subject = CommitMessageText.split(model.commitMessage).subject
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let message = CommitMessageText.preparedForCommit(model.commitMessage)
        guard model.isCommitDraftCurrent, let draft = model.commitDraft, model.snapshot?.operation == nil,
            !model.hasConflicts, !subject.isEmpty, model.snapshot?.changes.contains(where: \.isStaged) == true
        else {
            model.showError(String(localized: "Commit needs staged changes and a message"), "")
            return
        }
        let revision = draft.revision
        model.perform(
            String(localized: "Commit"),
            onSuccess: { [weak self] in
                guard let self, self.model.commitDraft === draft, draft.revision == revision,
                    !self.commitFooter.isComposing
                else { return }
                // Capture any open editor's text before comparing the revision again.
                if self.commitFooter.isEditing { self.model.setCommitMessage(self.commitFooter.message) }
                guard draft.revision == revision else { return }
                draft.setText("")
                _ = self.model.flushCommitDraft()
            },
            operation: { try await $0.commit(message: message) })
    }
}
