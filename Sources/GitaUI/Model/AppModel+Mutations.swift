import Foundation
import GitaCore

/// Git mutations. One runs at a time; each shows its status while it runs and reads the repository again after.
extension AppModel {
    /// The envelope every mutation shares: busy from here to `endMutation`, which reads the repository again
    /// (unless another one opened meanwhile). Returns the generation the mutation started in.
    private func beginMutation(_ statusText: String) -> Int {
        isMutating = true
        setStatus(statusText)
        emit(.status)
        return generation
    }

    /// `title` names the mutation in the toolbar's result (nil shows none).
    private func endMutation(_ started: Int, _ title: String? = nil, _ outcome: MutationResult.Outcome = .completed) {
        endMutation(started) {
            if let title { lastMutation = MutationResult(title: title, outcome: outcome) }
            refresh()
        }
    }

    /// Not busy any more: `then` runs for the repository the mutation started in. When another one opened meanwhile,
    /// its first read waited for the mutation (`pendingRefresh`) and starts now instead.
    private func endMutation(_ started: Int, then: () -> Void) {
        isMutating = false
        if started == generation {
            then()
        } else if pendingRefresh {
            refresh()
        }
        emit(.status)
    }

    /// Reviewed actions run only on the repository they were reviewed for, and never beside another mutation.
    private func requireIdle(_ expected: GitService, reopen review: StaleStateError.Review) throws {
        guard service === expected else { throw StaleStateError.repositoryChanged(review) }
        guard !isMutating else { throw StaleStateError.busy }
    }

    /// Logs the outcome; a stopped operation (conflicts, an edit stop) shows the Changes page.
    @discardableResult
    private func record(
        _ outcome: GitOperationOutcome, title: String, generation current: Int
    ) -> MutationResult.Outcome {
        switch outcome {
        case .completed:
            log(title, String(localized: "Completed"))
            return .completed
        case .stopped(let state, let diagnostic):
            log(String(localized: "\(state.kind.localizedTitle) paused"), diagnostic)
            if current == generation {
                staged = false
                section = .changes
            }
            return .paused
        }
    }

    /// Clone or initialize, then open the result. A failure leaves the open repository as it was: only a refresh
    /// asked for meanwhile runs, and the status says the clone or initialize failed.
    func acquire(remote: String?, destination: URL) {
        guard !isMutating else { return }
        let title = remote == nil ? String(localized: "Initialize repository") : String(localized: "Clone repository")
        let current = beginMutation(String(localized: "\(title)…"))
        Task {
            do {
                let result =
                    if let remote {
                        try await GitService.clone(remote: remote, to: destination)
                    } else {
                        try await GitService.initialize(at: destination)
                    }
                log(title, String(localized: "Completed"))
                endMutation(current) { open(result) }
            } catch {
                endMutation(current) {
                    if pendingRefresh { refresh() }
                    setStatus(String(localized: "\(title) failed"), failed: true)
                }
                log(title, error.localizedDescription, failed: true)
                showError(title, error.localizedDescription)
            }
        }
    }

    func perform(
        _ title: String, onSuccess: (() -> Void)? = nil,
        operation: @escaping @Sendable (GitService) async throws -> Void
    ) {
        guard let service, !isMutating else { return }
        let current = beginMutation(String(localized: "\(title)…"))
        Task {
            var outcome = MutationResult.Outcome.failed
            do {
                try await operation(service)
                log(title, String(localized: "Completed"))
                outcome = .completed
                if current == generation { onSuccess?() }
            } catch {
                log(title, error.localizedDescription, failed: true)
                showError(title, error.localizedDescription)
            }
            endMutation(current, title, outcome)
        }
    }

    func performGitOperation(
        _ title: String, operation: @escaping @Sendable (GitService) async throws -> GitOperationOutcome
    ) {
        guard let service, !isMutating else { return }
        let current = beginMutation(String(localized: "\(title)…"))
        Task {
            var outcome = MutationResult.Outcome.failed
            do {
                outcome = record(try await operation(service), title: title, generation: current)
            } catch {
                log(title, error.localizedDescription, failed: true)
                showError(title, error.localizedDescription)
            }
            endMutation(current, title, outcome)
        }
    }

    func resolveConflict(
        _ document: ConflictDocument, resolution: ConflictResolution, using expectedService: GitService
    ) async throws {
        try requireIdle(expectedService, reopen: .conflict)
        let current = beginMutation(RepositoryStatusText.resolvingConflict.rawValue)
        defer { endMutation(current) }
        do {
            try await expectedService.resolveConflict(document, resolution: resolution)
            log(String(localized: "Resolved conflict"), document.path)
        } catch {
            log(String(localized: "Conflict resolution failed"), error.localizedDescription, failed: true)
            throw error
        }
    }

    func applyReference(_ action: ReferenceReviewAction, using expectedService: GitService) async throws {
        try requireIdle(expectedService, reopen: .referenceAction)
        try await reviewed(action.localizedTitle, using: expectedService) { try await action.apply(with: $0) }
    }

    func applyInteractiveRebase(
        _ expected: GitInteractiveRebasePlan, steps: [GitRebaseStep], using expectedService: GitService
    ) async throws {
        try requireIdle(expectedService, reopen: .rebasePlan)
        let title = String(localized: "Interactive rebase")
        let current = beginMutation(RepositoryStatusText.rebasing.rawValue)
        var result = MutationResult.Outcome.failed
        defer { endMutation(current, title, result) }
        do {
            let outcome = try await expectedService.startInteractiveRebase(expected, steps: steps)
            result = record(outcome, title: title, generation: current)
            if case .completed = outcome, current == generation { section = .history }
        } catch {
            log(String(localized: "Interactive rebase failed"), error.localizedDescription, failed: true)
            throw error
        }
    }

    func applyReset(_ expected: GitResetPreview, mode: GitResetMode, using expectedService: GitService) async throws {
        try requireIdle(expectedService, reopen: .action)
        try await reviewed(String(localized: "Reset branch"), using: expectedService) { service in
            try await service.reset(expected, mode: mode)
        }
        if mode != .hard {
            staged = mode == .soft
            section = .changes
        }
    }

    func applyRemote(_ action: RemoteManagementAction, using expectedService: GitService) async throws {
        try requireIdle(expectedService, reopen: .action)
        try await reviewed(action.localizedTitle, using: expectedService) { try await action.apply(with: $0) }
    }

    /// A reviewed mutation: logged with `title`, its error thrown back to the review sheet that shows it.
    private func reviewed(
        _ title: String, using service: GitService, operation: (GitService) async throws -> Void
    ) async throws {
        let current = beginMutation(String(localized: "\(title)…"))
        var outcome = MutationResult.Outcome.failed
        defer { endMutation(current, title, outcome) }
        do {
            try await operation(service)
            log(title, String(localized: "Completed"))
            outcome = .completed
        } catch {
            log(title, error.localizedDescription, failed: true)
            throw error
        }
    }
}

extension ReferenceReviewAction {
    var localizedTitle: String {
        switch self {
        case .renameBranch: String(localized: "Rename branch")
        case .deleteBranch: String(localized: "Delete local branch")
        case .setUpstream(_, let upstream):
            if upstream == nil { String(localized: "Unset upstream") } else { String(localized: "Set upstream") }
        case .createTag: String(localized: "Create tag")
        case .deleteTag: String(localized: "Delete local tag")
        }
    }

    @MainActor func apply(with service: GitService) async throws {
        switch self {
        case .renameBranch(let expected, let name): try await service.renameBranch(expected, to: name)
        case .deleteBranch(let expected): try await service.deleteMergedBranch(expected)
        case .setUpstream(let expected, let upstream): try await service.setUpstream(expected, to: upstream)
        case .createTag(let name, let commitID, let annotation, let pushToAllRemotes):
            try await service.createTag(
                name: name, commitID: commitID, annotation: annotation, pushToAllRemotes: pushToAllRemotes)
        case .deleteTag(let expected, let deleteFromAllRemotes):
            try await service.deleteTag(expected, deleteFromAllRemotes: deleteFromAllRemotes)
        }
    }
}

extension RemoteManagementAction {
    var localizedTitle: String {
        switch self {
        case .add: String(localized: "Add remote")
        case .setURL: String(localized: "Edit remote URL")
        case .rename: String(localized: "Rename remote")
        case .remove: String(localized: "Remove remote")
        case .fetch: String(localized: "Fetch remote")
        }
    }

    @MainActor func apply(with service: GitService) async throws {
        switch self {
        case .add(let name, let url): try await service.addRemote(name: name, url: url)
        case .setURL(let expected, let url): try await service.setRemoteURL(expected, url: url)
        case .rename(let expected, let name): try await service.renameRemote(expected, to: name)
        case .remove(let expected): try await service.removeRemote(expected)
        case .fetch(let expected): try await service.fetchRemote(expected)
        }
    }
}
