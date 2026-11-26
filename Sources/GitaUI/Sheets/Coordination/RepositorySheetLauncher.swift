import AppKit
import GitaCore

/// Opens the review sheets for a tab's model: each sheet reads and writes through a `RepositoryGuard` for the
/// repository it was opened on, and the coordinator owns it while it shows.
@MainActor
struct RepositorySheetLauncher {
    let model: AppModel
    let coordinator: ReviewSheetCoordinator
    let window: NSWindow

    /// A sheet can open: nothing else is attached and no write runs.
    private var windowIsFree: Bool { window.attachedSheet == nil && !model.isMutating }

    /// The guard for the model's repository, when a history-changing sheet may open (a HEAD, no operation, no
    /// conflicts).
    private func historyGuard(failure: @escaping () -> Error) -> RepositoryGuard? {
        guard windowIsFree, !model.hasConflicts, let snapshot = model.snapshot, snapshot.head != nil,
            snapshot.operation == nil, let service = model.service
        else { return nil }
        return guarded(service, root: snapshot.root, failure: failure)
    }

    private func guarded(_ service: GitService, root: URL, failure: @escaping () -> Error) -> RepositoryGuard {
        RepositoryGuard(
            service: service, root: root, current: { [weak model] in model.map { ($0.service, $0.snapshot?.root) } },
            failure: failure)
    }

    private static func referenceChanged() -> Error {
        StaleStateError.repositoryChanged(.referenceAction)
    }

    func reviewReference(_ request: ReferenceReviewRequest) {
        // Showing a window can start a pending history refresh. The action's reference details load independently,
        // so that read must not drop an already accepted menu request. Writes still revalidate in GitService.
        guard let check = historyGuard(failure: Self.referenceChanged), let snapshot = model.snapshot else { return }
        let model = model
        let controller = ReferenceReviewController(
            request: request, references: snapshot.references, hasRemotes: !snapshot.remoteURLs.isEmpty,
            onLoad: { fullName in try await check.run { try await $0.referenceDetails(fullName: fullName) } },
            onApply: { [weak model] action in
                try await check.write {
                    guard let model else { throw Self.referenceChanged() }
                    try await model.applyReference(action, using: check.service)
                }
            })
        coordinator.present(ReviewSheetHandle(controller), service: check.service, on: window)
    }

    func reviewReset(_ commit: GitCommit) {
        guard let check = historyGuard(failure: { CancellationError() }) else { return }
        let controller = ResetReviewController(
            commit: commit,
            onLoad: { try await check.run { try await $0.resetPreview(to: commit.id) } },
            onApply: { [weak model] expected, mode in
                try await check.write {
                    try await model?.applyReset(expected, mode: mode, using: check.service)
                }
            })
        coordinator.present(ReviewSheetHandle(controller), service: check.service, on: window)
    }

    func reviewInteractiveRebase(after base: GitCommit, prefillActions: [String: GitRebaseAction] = [:]) {
        // Reopening a window can start a snapshot refresh after the menu has accepted this immutable base. The sheet
        // obtains its own fresh review.
        guard model.snapshot?.head != base.id, let check = historyGuard(failure: { CancellationError() }) else {
            return
        }
        let controller = InteractiveRebaseController(
            base: base,
            initialActions: prefillActions,
            speculativeService: SpeculativeGitService(gitService: check.service),
            onLoad: { try await check.run { try await $0.previewInteractiveRebase(after: base.id) } },
            onMessage: { commitID in
                let details = try await check.run { try await $0.commitDetails(ref: commitID) }
                guard details.commit.id == commitID else { throw CancellationError() }
                return details.message
            },
            onApply: { [weak model] expected, steps in
                try await check.write {
                    try await model?.applyInteractiveRebase(expected, steps: steps, using: check.service)
                }
            })
        coordinator.present(ReviewSheetHandle(controller), service: check.service, on: window)
    }

    func manageRemotes() {
        guard windowIsFree, let service = model.service, let root = model.snapshot?.root else { return }
        let check = guarded(service, root: root) { CancellationError() }
        let controller = RemoteManagementController(
            onLoad: { try await check.run { try await $0.remoteDetails() } },
            onApply: { [weak model] action in
                try await check.write { try await model?.applyRemote(action, using: check.service) }
            })
        coordinator.present(ReviewSheetHandle(controller), service: service, on: window)
    }
}
