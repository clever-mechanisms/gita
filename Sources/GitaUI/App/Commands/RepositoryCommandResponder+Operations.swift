import AppKit
import GitaCore

/// History-rewriting and reference commands: merge, rebase, cherry-pick, revert, reset, editing commits, branch and
/// tag changes, and the operation in progress (continue, skip, abort). Each is reviewed before it runs, and runs
/// only on the branch and commit it was reviewed on.
extension RepositoryCommandResponder {
    @objc func mergeBranch() { promptReference(rebase: false) }

    /// Force Push the current branch, asked first: it can replace commits on the remote.
    @objc func forcePush() {
        guard let branch = model.snapshot?.branch, let alerts = system?.alerts, let window = sheetWindow() else {
            return
        }
        RepositoryPrompts.forcePush(branch: branch, on: window, alerts: alerts) { [weak self] in
            self?.model.perform(String(localized: "Force Push")) { try await $0.push(force: true) }
        }
    }
    @objc func rebaseBranch() { promptReference(rebase: true) }
    func mergeReference(_ fullName: String) { promptReference(rebase: false, preselect: fullName) }
    func rebaseOntoReference(_ fullName: String) { promptReference(rebase: true, preselect: fullName) }

    /// The main window, shown first, when it can take a sheet.
    private func sheetWindow() -> NSWindow? {
        host?.showWindow()
        guard let window = host?.mainWindow, window.attachedSheet == nil else { return nil }
        return window
    }

    private func promptReference(rebase: Bool, preselect: String? = nil) {
        guard model.canStartOperation, let snapshot = model.snapshot, let service = model.service,
            let alerts = system?.alerts, let window = sheetWindow()
        else { return }
        let title = rebase ? GitOperationKind.rebase.localizedTitle : GitOperationKind.merge.localizedTitle
        RepositoryPrompts.reference(
            rebase: rebase, snapshot: snapshot, preselect: preselect, on: window, alerts: alerts,
            onPreview: { [weak self] ref, mode in
                self?.presentReferencePreview(
                    rebase: rebase, ref: ref, mode: mode, title: title, snapshot: snapshot, service: service,
                    on: window)
            }
        ) { [weak self] ref, mode in
            self?.runReviewedOperation(title, snapshot: snapshot, service: service) { git in
                if rebase { return try await git.rebase(onto: ref) }
                return try await git.merge(ref: ref, mode: mode)
            }
        }
    }

    private func presentReferencePreview(
        rebase: Bool, ref: String, mode: GitMergeMode, title: String, snapshot: RepositorySnapshot,
        service: GitService, on window: NSWindow
    ) {
        let speculative = SpeculativeGitService(gitService: service)
        let proceed: @MainActor () -> Void = { [weak self] in
            self?.runReviewedOperation(title, snapshot: snapshot, service: service) { git in
                if rebase { return try await git.rebase(onto: ref) }
                return try await git.merge(ref: ref, mode: mode)
            }
        }
        DispatchQueue.main.async {
            if rebase {
                Task { @MainActor in
                    let commits = (try? await service.previewInteractiveRebase(after: ref).commits) ?? []
                    let steps = commits.map { GitRebaseStep(commitID: $0.id) }
                    let panel =
                        steps.isEmpty
                        ? SpeculativeGitFacade.pairwisePreview(
                            service: speculative, ours: ref, theirs: snapshot.head ?? "HEAD")
                        : SpeculativeGitFacade.rebasePreview(service: speculative, onto: ref, steps: steps)
                    SpeculativeGitFacade.presentPreview(panel, on: window, proceedTitle: title, onProceed: proceed)
                }
            } else {
                let panel = SpeculativeGitFacade.pairwisePreview(
                    service: speculative, ours: snapshot.head ?? "HEAD", theirs: ref)
                SpeculativeGitFacade.presentPreview(panel, on: window, proceedTitle: title, onProceed: proceed)
            }
        }
    }

    @objc func cherryPickCommit() { promptCommitOperation(revert: false, commit: model.selectedCommit) }
    @objc func revertCommit() { promptCommitOperation(revert: true, commit: model.selectedCommit) }
    func cherryPick(_ commit: GitCommit) { promptCommitOperation(revert: false, commit: commit) }

    private func promptCommitOperation(revert: Bool, commit: GitCommit?) {
        guard model.canStartOperation, let snapshot = model.snapshot, let commit, let service = model.service,
            let alerts = system?.alerts, let window = sheetWindow()
        else { return }
        let title = revert ? GitOperationKind.revert.localizedTitle : GitOperationKind.cherryPick.localizedTitle
        var preview: (@MainActor (Int?) -> Void)?
        if !revert {
            preview = { [weak self] mainline in
                self?.presentCherryPickPreview(
                    commit: commit, mainline: mainline, title: title, snapshot: snapshot, service: service, on: window)
            }
        }
        RepositoryPrompts.commitOperation(
            title, commit: commit, branch: snapshot.localizedBranch, on: window, alerts: alerts, onPreview: preview
        ) { [weak self] mainline in
            self?.runReviewedOperation(title, snapshot: snapshot, service: service) { git in
                if revert { return try await git.revert(commit: commit.id, mainline: mainline) }
                return try await git.cherryPick(commit: commit.id, mainline: mainline)
            }
        }
    }

    private func presentCherryPickPreview(
        commit: GitCommit, mainline: Int?, title: String, snapshot: RepositorySnapshot,
        service: GitService, on window: NSWindow
    ) {
        let speculative = SpeculativeGitService(gitService: service)
        let proceed: @MainActor () -> Void = { [weak self] in
            self?.runReviewedOperation(title, snapshot: snapshot, service: service) { git in
                try await git.cherryPick(commit: commit.id, mainline: mainline)
            }
        }
        DispatchQueue.main.async {
            let panel = SpeculativeGitFacade.preFlightPreview(
                service: speculative, kind: .cherryPick, target: commit.id, onto: snapshot.head ?? "HEAD")
            SpeculativeGitFacade.presentPreview(panel, on: window, proceedTitle: title, onProceed: proceed)
        }
    }

    /// Runs `action` only while the repository is still on the branch and commit it was reviewed on.
    private func runReviewedOperation(
        _ title: String, snapshot: RepositorySnapshot, service: GitService,
        action: @escaping @Sendable (GitService) async throws -> GitOperationOutcome
    ) {
        guard model.service === service else {
            model.showError(title, String(localized: "The repository changed. Review the operation again."))
            return
        }
        model.performGitOperation(title) { git in
            let current = try await git.snapshot()
            guard current.head == snapshot.head, current.branch == snapshot.branch else {
                throw StaleStateError.branchChanged
            }
            return try await action(git)
        }
    }

    @objc func resetCommit() {
        guard model.canStartOperation, !model.hasConflicts, model.section == .history, let commit = model.selectedCommit
        else { return }
        host?.showWindow()
        host?.repositoryController?.reviewReset(commit)
    }

    @objc func editCommits() {
        guard model.canStartOperation, !model.hasConflicts, model.section == .history,
            let commit = model.selectedCommit, let root = model.snapshot?.root
        else { return }
        host?.showWindow()
        guard model.snapshot?.root == root else { return }
        host?.repositoryController?.reviewInteractiveRebase(after: commit)
    }

    // MARK: Branches and tags

    private func reviewReference(_ request: ReferenceReviewRequest) {
        guard model.canStartOperation, !model.hasConflicts else { return }
        host?.showWindow()
        host?.repositoryController?.reviewReference(request)
    }

    private static func fullName(_ sender: NSMenuItem) -> String? {
        (sender.representedObject as? GitReference)?.fullName
    }

    @objc func renameBranch(_ sender: NSMenuItem) { reviewReference(.renameBranch(Self.fullName(sender))) }
    @objc func deleteBranch(_ sender: NSMenuItem) { reviewReference(.deleteBranch(Self.fullName(sender))) }
    @objc func setBranchUpstream(_ sender: NSMenuItem) { reviewReference(.setUpstream(Self.fullName(sender))) }
    @objc func deleteTag(_ sender: NSMenuItem) { reviewReference(.deleteTag(Self.fullName(sender))) }

    @objc func createTag() {
        guard model.section == .history, let commit = model.selectedCommit else { return }
        reviewReference(.createTag(commit))
    }

    func createTagAt(_ commit: GitCommit) { reviewReference(.createTag(commit)) }

    func pushTag(_ name: String, to remote: String?) {
        model.perform(String(localized: "Push tag")) { try await $0.pushTag(name: name, to: remote) }
    }

    func deleteRemoteTag(_ name: String, on remote: String) {
        guard let window = sheetWindow(), let alerts = system?.alerts else { return }
        RepositoryPrompts.deleteRemoteTag(tag: name, remote: remote, on: window, alerts: alerts) { [weak self] in
            self?.model.perform(String(localized: "Delete remote tag")) {
                try await $0.deleteRemoteTag(name: name, on: remote)
            }
        }
    }

    // MARK: The operation in progress

    @objc func continueOperation() {
        guard let operation = model.snapshot?.operation, !model.hasConflicts else { return }
        model.performGitOperation(String(localized: "Continue \(operation.kind.localizedTitle)")) {
            try await $0.continueOperation(expected: operation)
        }
    }

    @objc func skipOperation() {
        guard let operation = model.snapshot?.operation, operation.canSkip else { return }
        confirmOperationAction(operation, skip: true)
    }

    @objc func abortOperation() {
        guard let operation = model.snapshot?.operation else { return }
        confirmOperationAction(operation, skip: false)
    }

    private func confirmOperationAction(_ operation: GitOperationState, skip: Bool) {
        guard let window = sheetWindow(), let service = model.service, let alerts = system?.alerts else { return }
        let title =
            skip
            ? String(localized: "Skip current commit") : String(localized: "Abort \(operation.kind.localizedTitle)")
        RepositoryPrompts.operationAction(operation, skip: skip, on: window, alerts: alerts) { [weak self] in
            guard let self, self.model.service === service else { return }
            self.model.performGitOperation(title) { git in
                if skip { return try await git.skipOperation(expected: operation) }
                return try await git.abortOperation(expected: operation)
            }
        }
    }
}
