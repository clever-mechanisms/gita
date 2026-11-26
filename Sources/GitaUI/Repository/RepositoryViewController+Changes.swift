import AppKit
import GitaCore

/// Local Changes: choosing, staging and unstaging files, and the commit footer.
extension RepositoryViewController {
    func wireFileLists() {
        wireQuickLook()
        wireSmartDiff()
        filePane.isMutating = { [weak self] in self?.model.isMutating ?? false }
        filePane.onStage = { [weak self] files, staged in self?.setStaged(files, staged) }
        filePane.onStageAll = { [weak self] in self?.stageAllFiles() }
        filePane.onUnstageAll = { [weak self] in self?.unstageAllFiles() }
        filePane.onDiscard = { [weak self] files in self?.confirmDiscard(files.filter { !$0.isConflict }) }
        filePane.onPush = { [weak self] in self?.pushFromCleanTreeEmptyState() }
        filePane.commitFiles.onSelect = { [weak self] file in
            self?.closeBlame()
            self?.model.selectFile(file)
        }
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
        commitFooter.onCommit = { [weak self] in self?.commitChanges() }
        commitFooter.onCommitAndPush = { [weak self] in self?.commitChanges(andPush: true) }
        commitFooter.onAmend = { [weak self] in self?.toggleAmend() }
        commitFooter.onFillRecent = { [weak self] text in
            self?.fillRecentCommitMessage(text)
            self?.updateCommitActions()
        }
        commitFooter.onWillOpenRecents = { [weak self] in self?.refreshRecentMessagesIfNeeded(force: true) }
    }

    /// A file clicked in Unstaged or Staged: that side's diff.
    func chooseChange(_ file: FileChange, staged: Bool) {
        closeBlame()
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
        guard !paths.isEmpty, !model.isMutating else { return }
        if amend.source != nil { amendUnstagedPaths.subtract(paths) }
        model.perform(String(localized: "Stage all")) { try await $0.stage(paths: paths) }
    }

    func unstageAllFiles() {
        let files: [FileChange] =
            if case .armed(_, _, let amendFiles) = model.amendStaging {
                amendFiles
            } else {
                model.snapshot?.changes.filter { !$0.isConflict && $0.isStaged } ?? []
            }
        setStaged(files, false)
    }

    func fillRecentCommitMessage(_ text: String) {
        if case .armed = amend {
            amend = amend.withMessage(text)
        } else {
            model.draftController.setText(text, preservingUnsentDraft: true)
        }
    }

    func refreshRecentMessagesIfNeeded(force: Bool = false) {
        guard model.section == .changes, let snapshot = model.snapshot, let service = model.service else { return }
        guard let head = snapshot.head else {
            panes.recentMessagesKey = snapshot.root.path + "#unborn"
            commitFooter.recentMessages = []
            return
        }
        let key = snapshot.root.path + "#" + head
        guard force || panes.recentMessagesKey != key else { return }
        panes.recentMessagesKey = key
        Task { [weak self] in
            let loaded = (try? await service.recentCommitMessages()) ?? []
            guard let self, self.model.service === service, self.model.snapshot?.head == head else { return }
            self.commitFooter.recentMessages = loaded
        }
    }

    func updateCommitActions() {
        reconcileAmend()
        let snapshot = model.snapshot
        let source = amend.source
        let stagedCount =
            if case .armed(_, _, let amendFiles) = model.amendStaging {
                amendFiles.count
            } else {
                snapshot?.changes.count { !$0.isConflict && $0.isStaged } ?? 0
            }
        commitFooter.lastUnsentDraft = model.draftController.lastUnsentDraft
        commitFooter.apply(
            CommitActionsState(
                .init(
                    hasSnapshot: snapshot != nil, hasDraft: model.commitDraft != nil,
                    isDraftCurrent: model.isCommitDraftCurrent, hasOperation: snapshot?.operation != nil,
                    hasConflicts: model.hasConflicts, isMutating: model.isMutating,
                    stagedCount: stagedCount, hasHead: snapshot?.head != nil, mode: amend.mode,
                    amendCommitID: source?.id, upstreamName: source?.upstream, message: commitFooter.message)))
        refreshRecentMessagesIfNeeded()
        updateCommitMessageAssistAvailability()
        if commitSigningRowState.isMutating && !model.isMutating {
            refreshCommitSigningAndTemplateIfNeeded(force: true)
        }
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

    func commitChanges(andPush: Bool = false) {
        if amend.source != nil {
            amendArmedCommit(andPush: andPush)
            return
        }
        noteCommitField(commitFooter.message)
        let subject = CommitMessageText.split(model.commitMessage).subject
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let message = CommitMessageText.preparedForCommit(model.commitMessage)
        guard model.isCommitDraftCurrent, let draft = model.commitDraft, model.snapshot?.operation == nil,
            !model.hasConflicts, !subject.isEmpty, model.snapshot?.changes.contains(where: \.isStaged) == true
        else {
            model.showBanner(.info(String(localized: "Commit needs staged changes and a message")))
            return
        }
        let revision = draft.revision
        let expectedService = model.service
        model.perform(
            String(localized: "Commit"),
            onSuccess: { [weak self] in
                guard let self else { return }
                if self.model.commitDraft === draft, draft.revision == revision, !self.commitFooter.isComposing {
                    // Capture any open editor's text before comparing the revision again.
                    if self.commitFooter.isEditing { self.model.setCommitMessage(self.commitFooter.message) }
                    if draft.revision == revision { self.model.draftController.clearCommittedDraft() }
                }
                if andPush, let expectedService {
                    DispatchQueue.main.async { [weak self] in self?.pushAfterCommit(using: expectedService) }
                }
            },
            operation: { try await $0.commit(message: message) })
    }

    func pushAfterCommit(using expectedService: GitService) {
        guard model.service === expectedService, !model.isMutating else { return }
        Task<Void, Never> { [weak self] in
            guard let self, self.model.service === expectedService else { return }
            let branch = self.model.snapshot?.branch
            let upstreams: [String: GitBranchUpstream]
            do {
                upstreams = try await expectedService.branchUpstreams()
            } catch {
                upstreams = [:]
            }
            guard self.model.service === expectedService, !self.model.isMutating else { return }
            self.finishPushAfterCommit(hasUpstream: branch.flatMap { upstreams[$0] } != nil)
        }
    }

    private func finishPushAfterCommit(hasUpstream: Bool) {
        if hasUpstream {
            model.perform(String(localized: "Push")) { try await $0.push() }
        } else if let commands {
            commands.push()
        } else {
            NSApp.sendAction(#selector(RepositoryCommandResponder.push), to: nil, from: self)
        }
    }

    func updateCleanTreeContext() {
        guard let snapshot = model.snapshot else {
            filePane.cleanTreeContext = nil
            return
        }
        let hasUpstream =
            snapshot.ahead > 0 || snapshot.behind > 0
            || (snapshot.branch.map { branch in
                snapshot.references.contains { $0.kind == .remote && $0.name.hasSuffix("/" + branch) }
            } ?? false)
        filePane.cleanTreeContext = CleanTreeContext(
            lastCommitDate: snapshot.commits.first?.date,
            ahead: snapshot.ahead,
            hasUpstream: hasUpstream,
            canPush: !model.isMutating && snapshot.operation == nil && snapshot.remoteURL != nil)
    }

    private func pushFromCleanTreeEmptyState() {
        guard model.snapshot != nil, !model.isMutating else { return }
        if let responder = commands as? RepositoryCommandResponder {
            responder.pushOrSheet()
        } else if let commands {
            commands.push()
        } else {
            NSApp.sendAction(#selector(RepositoryCommandResponder.pushOrSheet), to: nil, from: self)
        }
    }
}
