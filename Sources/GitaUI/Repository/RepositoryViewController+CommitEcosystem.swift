import AppKit
import GitaCore

/// Commit signing badges, per-repository signing toggle & template loader, and CLI AI commit message generation.
extension RepositoryViewController {
    func wireCommitEcosystem() {
        commitFooter.signingRow.onToggleSigning = { [weak self] enabled in
            self?.toggleCommitSigning(enabled)
        }
        commitFooter.signingRow.onApplyTemplate = { [weak self] content in
            self?.applyCommitTemplate(content)
        }
        commitFooter.assistController.button.onClick = { [weak self] in
            self?.toggleGenerateCommitMessage()
        }
        commitFooter.assistController.onApplyMessage = { [weak self] generated in
            self?.applyGeneratedCommitMessage(generated)
        }
        commitFooter.assistController.onStateChanged = { [weak self] state in
            if case .failed(let message) = state {
                self?.model.showBanner(
                    .failure(title: String(localized: "Commit message generation failed"), message: message, retry: nil)
                )
            }
        }
        updateCommitMessageAssistAvailability()
    }

    func detachCommitEcosystem() {
        commitSignatureTask?.cancel()
        commitSignatureTask = nil
        commitSigningTask?.cancel()
        commitSigningTask = nil
        commitFooter.assistController.cancel()
    }

    func commitEcosystemRepositoryChanged() {
        let currentRoot = model.snapshot?.root.standardizedFileURL.path
        if loadedSigningRepoPath != currentRoot {
            commitSignatureCache.removeAll()
            commitSignatureTask?.cancel()
            commitSignatureTask = nil
            commitSigningTask?.cancel()
            commitSigningTask = nil
            commitFooter.assistController.reset()
            loadedSigningRepoPath = nil
            commitSigningRowState = CommitSigningRowState(signing: .loading, template: nil)
            commitFooter.signingRow.apply(commitSigningRowState)
        }
        if model.section == .changes {
            refreshCommitSigningAndTemplateIfNeeded()
        }
    }

    func loadCommitSignatureIfNeeded(for commit: GitCommit?) {
        commitSignatureTask?.cancel()
        commitSignatureTask = nil
        guard let commit, commitSignatureCache[commit.id] == nil, let service = model.service else { return }
        let commitID = commit.id
        commitSignatureTask = Task { [weak self] in
            let info = try? await service.commitSignature(for: commitID)
            guard let self, !Task.isCancelled, self.model.service === service,
                self.model.selectedCommit?.id == commitID
            else { return }
            let resolved = info ?? CommitSignatureInfo(status: .none, signer: nil, keyID: nil, fingerprint: nil)
            if self.commitSignatureCache.count >= 256 { self.commitSignatureCache.removeAll() }
            self.commitSignatureCache[commitID] = resolved
            self.rebuildCommitDetail()
        }
    }

    func refreshCommitSigningAndTemplateIfNeeded(force: Bool = false) {
        guard let service = model.service, let root = model.snapshot?.root else { return }
        let key = root.standardizedFileURL.path
        guard force || loadedSigningRepoPath != key else { return }
        loadedSigningRepoPath = key
        commitSigningTask?.cancel()
        commitSigningTask = Task { [weak self] in
            async let signingResult: Result<CommitSigningConfig, Error> = {
                do { return .success(try await service.signingConfig()) } catch { return .failure(error) }
            }()
            async let templateResult = CommitTemplateLoader.load(service: service)
            let (signing, template) = await (signingResult, templateResult)
            guard let self, !Task.isCancelled, self.model.service === service else { return }
            let configState: CommitSigningConfigState =
                switch signing {
                case .success(let config): .loaded(config)
                case .failure(let error): .failed(error.localizedDescription)
                }
            self.commitSigningRowState = CommitSigningRowState(signing: configState, template: template)
            self.commitFooter.signingRow.apply(self.commitSigningRowState)
            self.preloadCommitTemplateIfNeeded(template, repoPath: key)
        }
    }

    func updateCommitMessageAssistAvailability() {
        let stagedCount =
            if case .armed(_, _, let amendFiles) = model.amendStaging {
                amendFiles.count
            } else {
                model.snapshot?.changes.count { !$0.isConflict && $0.isStaged } ?? 0
            }
        commitFooter.assistController.updateAvailability(
            hasStagedChanges: stagedCount > 0,
            installedAgents: ReviewAgentLauncher.shared.installed,
            preferredAgent: Preference.reviewAgent.string(model.defaults)
        )
    }

    private func toggleCommitSigning(_ enabled: Bool) {
        guard let config = commitSigningRowState.config, !model.isMutating else { return }
        commitSigningRowState.signing = .mutating(config)
        commitFooter.signingRow.apply(commitSigningRowState)
        model.perform(
            String(localized: "Toggle commit signing"),
            onSuccess: { [weak self] in self?.refreshCommitSigningAndTemplateIfNeeded(force: true) },
            operation: { try await $0.setLocalCommitSigning(enabled) }
        )
    }

    private func applyCommitTemplate(_ content: String) {
        guard !content.isEmpty else { return }
        commitFooter.show(message: content)
        noteCommitField(content)
        updateCommitActions()
    }

    private func preloadCommitTemplateIfNeeded(_ template: CommitTemplateResult?, repoPath: String) {
        guard let template, !template.content.isEmpty,
            model.isCommitDraftCurrent, model.commitMessage.isEmpty,
            !commitFooter.isEditing, amend.source == nil,
            appliedTemplateRepoPaths.insert(repoPath).inserted
        else { return }
        applyCommitTemplate(template.content)
    }

    private func toggleGenerateCommitMessage() {
        guard let service = model.service else { return }
        commitFooter.assistController.toggleGenerate(service: service)
    }

    private func applyGeneratedCommitMessage(_ generated: GeneratedCommitMessage) {
        let text = generated.fullMessage
        commitFooter.show(message: text)
        noteCommitField(text)
        updateCommitActions()
    }
}
