import AppKit
import GitaCore

/// Complete stash creation/actions (Feature #5) wired into Local Changes and the sidebar stash rows.
extension RepositoryViewController {
    func presentCreateStashSheet(selectedPaths: [String] = []) -> Bool {
        guard let window = view.window, let snapshot = model.snapshot, let service = model.service,
            !model.isMutating
        else { return false }
        let paths = selectedPaths.isEmpty ? selectedLocalChangePaths() : selectedPaths
        CreateStashSheet.present(
            on: window, alerts: model.alerts, changes: snapshot.changes, selectedPaths: paths,
            execute: { request in try await service.createStash(request) },
            completion: { [weak self] created in
                if created { self?.model.refresh() }
            }
        )
        return true
    }

    private func selectedLocalChangePaths() -> [String] {
        let unstaged = filePane.unstaged.list.selectedFiles.map(\.path)
        let staged = filePane.staged.list.selectedFiles.map(\.path)
        var seen = Set<String>()
        return (unstaged + staged).filter { seen.insert($0).inserted }
    }

    func stashContextMenu(for stash: GitStash) -> NSMenu {
        StashActionPresenter.menu(for: stash, enabled: !model.isMutating) { [weak self] action, target in
            self?.performStashAction(action, on: target)
        }
    }

    private func performStashAction(_ action: StashAction, on stash: GitStash) {
        guard !model.isMutating else { return }
        executeStashAction(action, on: stash)
    }

    private func executeStashAction(_ action: StashAction, on stash: GitStash) {
        switch action {
        case .pop:
            popStash(stash, restoreIndex: true)
        case .apply:
            model.perform(String(localized: "Apply stash")) {
                try await $0.applyStash(ref: stash.ref, expectedCommitID: stash.commitID)
            }
        case .createBranch, .drop:
            promptStashAction(action, on: stash)
        }
    }

    private func promptStashAction(_ action: StashAction, on stash: GitStash) {
        guard let window = view.window else { return }
        if action == .createBranch {
            StashActionPresenter.promptForBranch(stash, on: window) { [weak self] name in
                self?.model.perform(String(localized: "Create branch from stash")) {
                    try await $0.createBranchFromStash(name: name, ref: stash.ref, expectedCommitID: stash.commitID)
                }
            }
            return
        }
        StashActionPresenter.confirmDrop(stash, on: window) { [weak self] in
            self?.model.perform(String(localized: "Drop stash")) {
                try await $0.dropStash(ref: stash.ref, expectedCommitID: stash.commitID)
            }
        }
    }

    private func popStash(_ stash: GitStash, restoreIndex: Bool) {
        model.performWithResult(
            String(localized: "Pop stash"),
            onSuccess: { [weak self] outcome in
                guard let self, let window = self.view.window else { return }
                StashActionPresenter.presentPopOutcome(outcome, for: stash, on: window) { [weak self] in
                    self?.popStash(stash, restoreIndex: false)
                }
            },
            onFailure: { [weak self] _, error in
                self?.model.showBanner(
                    .failure(
                        title: String(localized: "Pop stash failed"),
                        message: error.localizedDescription,
                        retry: nil
                    )
                )
            },
            operation: { service in
                try await service.popStash(
                    ref: stash.ref, expectedCommitID: stash.commitID, restoreIndex: restoreIndex)
            }
        )
    }
}
