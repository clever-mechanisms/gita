import AppKit
import GitaCore

/// Fetch, Pull and Push: each asks first in a sheet (which remote, which branch, how), then runs on the tab's model.
extension RepositoryCommandResponder {
    @objc func fetch() {
        presentSync(String(localized: "Fetch")) { [weak self] choices, window, alerts in
            FetchSheet(choices: choices).present(on: window, alerts: alerts) { remote in
                self?.model.perform(String(localized: "Fetch")) { try await $0.fetch(remote: remote) }
            }
        }
    }

    /// Pull into the checked-out branch; a merge or rebase that conflicts stops like Merge.
    @objc func pull() {
        presentSync(String(localized: "Pull")) { [weak self] choices, window, alerts in
            guard let self else { return }
            guard let current = choices.current else {
                model.showError(String(localized: "Pull"), String(localized: "Check out a branch to pull into."))
                return
            }
            PullSheet(choices: choices, into: current).present(on: window, alerts: alerts) { [weak self] request in
                self?.model.performGitOperation(String(localized: "Pull")) { try await $0.pull(request) }
            }
        }
    }

    @objc func push() { showPush(selecting: nil) }

    func pushBranch(_ name: String) { showPush(selecting: name) }

    /// Push with `name` chosen in the sheet; nil chooses the checked-out branch.
    private func showPush(selecting name: String?) {
        presentSync(String(localized: "Push")) { [weak self] choices, window, alerts in
            guard let self else { return }
            guard !choices.branches.isEmpty else {
                model.showError(String(localized: "Push"), String(localized: "This repository has no branch to push."))
                return
            }
            PushSheet(choices: choices, branch: name ?? choices.current).present(on: window, alerts: alerts) {
                [weak self] request in
                self?.model.perform(String(localized: "Push")) { try await $0.push(request) }
            }
        }
    }

    /// The checked-out branch to its upstream at once, without the sheet (the menu bar panel's Push).
    func pushNow() { model.perform(String(localized: "Push")) { try await $0.push() } }

    /// Shows a sheet built from the remotes and branches as they are now; nothing while the main window already
    /// has a sheet, an error when there is no remote.
    private func presentSync(
        _ title: String, build: @escaping @MainActor (SyncChoices, NSWindow, AlertPresenter) -> Void
    ) {
        guard var snapshot = model.snapshot, let service = model.service else { return }
        Task { [weak self] in
            snapshot.remoteURLs = await service.remoteURLs()
            let upstreams = (try? await service.branchUpstreams()) ?? [:]
            guard let self, model.service === service, let alerts = system?.alerts else { return }
            guard !snapshot.remoteURLs.isEmpty else {
                model.showError(title, String(localized: "This repository has no remote."))
                return
            }
            host?.showWindow()
            guard let window = host?.mainWindow, window.attachedSheet == nil else { return }
            build(SyncChoices(snapshot: snapshot, upstreams: upstreams), window, alerts)
        }
    }
}
