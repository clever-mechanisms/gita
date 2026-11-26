import AppKit
import GitaCore

/// Complete stash creation/actions (Feature #5) wired into Local Changes and the sidebar stash rows.
extension RepositoryViewController {
    func presentCreateStashSheet(selectedPaths: [String]? = nil) -> Bool {
        guard let window = view.window, let snapshot = model.snapshot, let service = model.service,
            !model.isMutating
        else { return false }
        let paths = selectedPaths ?? selectedLocalChangePaths()
        CreateStashSheet.present(
            on: window, changes: snapshot.changes, selectedPaths: paths,
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
        StashActionPresenter.menu(for: stash) { [weak self] action, target in
            self?.performStashAction(action, on: target)
        }
    }

    private func performStashAction(_ action: StashAction, on stash: GitStash) {
        guard !model.isMutating else { return }
        switch action {
        case .pop:
            popStash(stash, restoreIndex: true)
        case .apply:
            model.perform(String(localized: "Apply stash")) { try await $0.applyStash(ref: stash.ref) }
        case .createBranch:
            guard let window = view.window else { return }
            StashActionPresenter.promptForBranch(stash, on: window) { [weak self] name in
                self?.model.perform(String(localized: "Create branch from stash")) {
                    try await $0.createBranchFromStash(name: name, ref: stash.ref)
                }
            }
        case .drop:
            guard let window = view.window else { return }
            StashActionPresenter.confirmDrop(stash, on: window) { [weak self] in
                self?.model.perform(String(localized: "Drop stash")) { try await $0.dropStash(ref: stash.ref) }
            }
        }
    }

    private func popStash(_ stash: GitStash, restoreIndex: Bool) {
        guard let service = model.service else { return }
        Task { [weak self] in
            do {
                let outcome = try await service.popStash(ref: stash.ref, restoreIndex: restoreIndex)
                guard let self else { return }
                self.model.refresh()
                if let window = self.view.window {
                    StashActionPresenter.presentPopOutcome(outcome, for: stash, on: window) { [weak self] in
                        self?.popStash(stash, restoreIndex: false)
                    }
                }
            } catch {
                self?.model.showBanner(
                    .failure(title: String(localized: "Pop stash failed"), message: error.localizedDescription, retry: nil)
                )
            }
        }
    }
}
