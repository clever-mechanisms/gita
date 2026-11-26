import AppKit
import GitaCore

/// Single-enum lifecycle for an in-flight commit signature lookup.
enum CommitSignatureFetch {
    case idle
    case loading(commitID: String, task: Task<Void, Never>)

    mutating func cancel() {
        if case .loading(_, let task) = self { task.cancel() }
        self = .idle
    }
}

/// Single-enum lifecycle for loading repository commit signing config and template.
enum CommitSigningLoad {
    case idle
    case loading(repoPath: String, task: Task<Void, Never>)
    case loaded(repoPath: String)

    mutating func cancel() {
        if case .loading(_, let task) = self { task.cancel() }
        self = .idle
    }

    func matches(_ repoPath: String) -> Bool {
        switch self {
        case .idle: false
        case .loading(let current, _), .loaded(let current): current == repoPath
        }
    }
}

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
        commitSignatureFetch.cancel()
        commitSigningLoad.cancel()
        commitFooter.assistController.cancel()
    }

    func commitEcosystemRepositoryChanged() {
        let currentRoot = model.snapshot?.root.standardizedFileURL.path
        if commitEcosystemRootPath != currentRoot {
            commitEcosystemRootPath = currentRoot
            commitSignatureCache.removeAll()
            commitSignatureFetch.cancel()
            commitSigningLoad.cancel()
            commitFooter.assistController.reset()
            commitSigningRowState = CommitSigningRowState(signing: .loading, template: nil)
            commitFooter.signingRow.apply(commitSigningRowState)
        }
        if isShowingLocalChanges {
            refreshCommitSigningAndTemplateIfNeeded()
        }
    }

    func loadCommitSignatureIfNeeded(for commit: GitCommit?) {
        guard let commit, let service = model.service else {
            commitSignatureFetch.cancel()
            return
        }
        if commitSignatureCache[commit.id] != nil {
            commitSignatureFetch.cancel()
            return
        }
        if case .loading(let activeID, _) = commitSignatureFetch, activeID == commit.id {
            return
        }
        commitSignatureFetch.cancel()
        let commitID = commit.id
        let task = Task { [weak self] in
            do {
                let info = try await service.commitSignature(for: commitID)
                guard let self, !Task.isCancelled, self.model.service === service else { return }
                if case .loading(let currentID, _) = self.commitSignatureFetch, currentID == commitID {
                    self.commitSignatureFetch = .idle
                }
                if self.commitSignatureCache.count >= 256 { self.commitSignatureCache.removeAll() }
                self.commitSignatureCache[commitID] = info
                if self.model.selectedCommit?.id == commitID { self.rebuildCommitDetail() }
            } catch {
                guard let self else { return }
                if case .loading(let currentID, _) = self.commitSignatureFetch, currentID == commitID {
                    self.commitSignatureFetch = .idle
                }
            }
        }
        commitSignatureFetch = .loading(commitID: commitID, task: task)
    }

    func refreshCommitSigningAndTemplateIfNeeded(force: Bool = false) {
        guard let service = model.service, let root = model.snapshot?.root else { return }
        let key = root.standardizedFileURL.path
        guard force || !commitSigningLoad.matches(key) else { return }
        commitSigningLoad.cancel()
        let task = Task { [weak self] in
            async let signingResult: Result<CommitSigningConfig, Error> = {
                do { return .success(try await service.signingConfig()) } catch { return .failure(error) }
            }()
            async let templateResult = CommitTemplateLoader.load(service: service)
            let (signing, template) = await (signingResult, templateResult)
            guard let self, !Task.isCancelled, self.model.service === service else { return }
            self.commitSigningLoad = .loaded(repoPath: key)
            let configState: CommitSigningConfigState =
                switch signing {
                case .success(let config): .loaded(config)
                case .failure(let error): .failed(error.localizedDescription)
                }
            self.commitSigningRowState = CommitSigningRowState(signing: configState, template: template)
            self.commitFooter.signingRow.apply(self.commitSigningRowState)
            self.preloadCommitTemplateIfNeeded(template, repoPath: key)
        }
        commitSigningLoad = .loading(repoPath: key, task: task)
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
        model.log(String(localized: "Generate commit message"), generated.agent.displayName)
    }
}
