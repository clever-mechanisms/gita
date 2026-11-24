import AppKit
import GitaCore

/// Pure sync-click routing for one-click toolbar Fetch / Pull / Push.
enum ToolbarSyncDecision {
    static func shouldPushNow(
        branch: String?, upstreams: [String: GitBranchUpstream], remotes: [String: String]
    ) -> Bool {
        guard let branch, let upstream = upstreams[branch], remotes[upstream.remote] != nil else { return false }
        return true
    }

    static func directPullRequest(
        branch: String?, upstreams: [String: GitBranchUpstream], remotes: [String: String],
        preferredMode: GitPullMode, ahead: Int
    ) -> GitPullRequest? {
        guard let branch, let upstream = upstreams[branch], remotes[upstream.remote] != nil else { return nil }
        guard preferredMode == .fastForwardOnly || ahead == 0 else { return nil }
        return GitPullRequest(remote: upstream.remote, branch: upstream.branch, mode: .fastForwardOnly)
    }
}

/// Fetch, Pull and Push: toolbar clicks act immediately when safe (hardened fetch, FF-only pull, push with upstream);
/// menu items and toolbar chevrons open the options sheets.
extension RepositoryCommandResponder {
    @objc func fetch() {
        presentSync(String(localized: "Fetch")) { [weak self] choices, window, alerts in
            FetchSheet(choices: choices).present(on: window, alerts: alerts) { remote in
                self?.runFetch(remote: remote)
            }
        }
    }

    @objc func fetchNow() {
        guard let service = model.service else { return }
        Task { [weak self] in
            let remotes = await service.remoteURLs()
            guard let self, model.service === service else { return }
            guard !remotes.isEmpty else {
                model.showBanner(.info(String(localized: "This repository has no remote.")))
                return
            }
            runFetch(remote: nil)
        }
    }

    private func runFetch(remote: String?) {
        model.perform(
            String(localized: "Fetch"),
            onSuccess: { [weak self] in self?.model.dismissBanner() },
            onFailure: { [weak self] title, error in
                let retry = ContentBanner.RetryAction(title: String(localized: "Retry")) { [weak self] in
                    self?.runFetch(remote: remote)
                }
                self?.model.showNonDestructiveError(title, error.localizedDescription, retry: retry)
            },
            operation: { try await $0.fetch(remote: remote) })
    }

    /// Pull into the checked-out branch; a merge or rebase that conflicts stops like Merge.
    @objc func pull() {
        presentSync(String(localized: "Pull")) { [weak self] choices, window, alerts in
            guard let self else { return }
            guard let current = choices.current else {
                model.showBanner(.info(String(localized: "Check out a branch to pull into.")))
                return
            }
            PullSheet(choices: choices, into: current).present(on: window, alerts: alerts) { [weak self] request in
                self?.performDirectPull(request)
            }
        }
    }

    @objc func pullNow() {
        withRemoteContext(String(localized: "Pull")) { [weak self] snapshot, remotes, upstreams in
            guard let self else { return }
            guard let current = snapshot.branch else {
                model.showBanner(.info(String(localized: "Check out a branch to pull into.")))
                return
            }
            let preferredMode = GitPullMode(rawValue: Preference.pullMode.string(model.defaults)) ?? .fastForwardOnly
            if let request = ToolbarSyncDecision.directPullRequest(
                branch: current, upstreams: upstreams, remotes: remotes, preferredMode: preferredMode,
                ahead: snapshot.ahead)
            {
                performDirectPull(request)
            } else {
                pull()
            }
        }
    }

    private func performDirectPull(_ request: GitPullRequest) {
        model.performGitOperation(
            String(localized: "Pull"),
            onFailure: { [weak self] title, error in
                let retry = ContentBanner.RetryAction(title: String(localized: "Retry")) { [weak self] in
                    self?.performDirectPull(request)
                }
                self?.model.showNonDestructiveError(title, error.localizedDescription, retry: retry)
            },
            operation: { try await $0.pull(request) })
    }

    @objc func push() { showPush(selecting: nil) }

    @objc func pushOrSheet() {
        withRemoteContext(String(localized: "Push")) { [weak self] snapshot, remotes, upstreams in
            guard let self else { return }
            if ToolbarSyncDecision.shouldPushNow(branch: snapshot.branch, upstreams: upstreams, remotes: remotes) {
                pushNow()
            } else {
                push()
            }
        }
    }

    private func withRemoteContext(
        _: String,
        perform: @escaping @MainActor (RepositorySnapshot, [String: String], [String: GitBranchUpstream]) -> Void
    ) {
        guard let snapshot = model.snapshot, let service = model.service else { return }
        Task { [weak self] in
            let remotes = await service.remoteURLs()
            let upstreams = (try? await service.branchUpstreams()) ?? [:]
            guard let self, model.service === service else { return }
            guard !remotes.isEmpty else {
                model.showBanner(.info(String(localized: "This repository has no remote.")))
                return
            }
            perform(snapshot, remotes, upstreams)
        }
    }

    func pushBranch(_ name: String) { showPush(selecting: name) }

    /// Push with `name` chosen in the sheet; nil chooses the checked-out branch.
    private func showPush(selecting name: String?) {
        presentSync(String(localized: "Push")) { [weak self] choices, window, alerts in
            guard let self else { return }
            guard !choices.branches.isEmpty else {
                model.showBanner(.info(String(localized: "This repository has no branch to push.")))
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
        _: String, build: @escaping @MainActor (SyncChoices, NSWindow, AlertPresenter) -> Void
    ) {
        guard var snapshot = model.snapshot, let service = model.service else { return }
        Task { [weak self] in
            snapshot.remoteURLs = await service.remoteURLs()
            let upstreams = (try? await service.branchUpstreams()) ?? [:]
            guard let self, model.service === service, let alerts = system?.alerts else { return }
            guard !snapshot.remoteURLs.isEmpty else {
                model.showBanner(.info(String(localized: "This repository has no remote.")))
                return
            }
            host?.showWindow()
            guard let window = host?.mainWindow, window.attachedSheet == nil else { return }
            build(SyncChoices(snapshot: snapshot, upstreams: upstreams), window, alerts)
        }
    }
}
