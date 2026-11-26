import AppKit
import GitaCore

/// Paste-Anything Teleport, `gita://` deep-link resolution, and cross-workspace navigation.
extension AppDelegate {
    /// Repositories ordered with the active workspace first, followed by other workspaces and recents.
    func teleportRepositories() -> [TeleportRepositoryEntry] {
        var modelsByPath: [String: AppModel] = [:]
        for window in places {
            for openModel in window.models {
                if let root = openModel.snapshot?.root ?? openModel.root {
                    modelsByPath[root.standardizedFileURL.resolvingSymlinksInPath().path] = openModel
                }
            }
        }
        var seen = Set<String>()
        var entries: [TeleportRepositoryEntry] = []

        func append(root: URL, workspace: Workspace) {
            let key = root.standardizedFileURL.resolvingSymlinksInPath().path
            guard seen.insert(key).inserted else { return }
            let openModel = modelsByPath[key]
            let snapshot = openModel?.snapshot
            let githubSlug = snapshot?.github.map { remote -> String in
                let prefix = "github:"
                return remote.sourceID.hasPrefix(prefix)
                    ? String(remote.sourceID.dropFirst(prefix.count)) : remote.sourceID
            }
            let remoteURLs = snapshot.map { Array($0.remoteURLs.values) } ?? []
            entries.append(
                TeleportRepositoryEntry(
                    workspaceID: workspace.id,
                    workspaceTitle: workspace.title,
                    repoPath: root,
                    displayName: root.lastPathComponent,
                    remoteURLs: remoteURLs,
                    githubSlug: githubSlug))
        }

        // Active workspace leads so ambiguous results favor the workspace in front.
        let orderedWorkspaces = [place.workspace] + workspaces.workspaces.filter { $0.id != place.workspace.id }
        for workspace in orderedWorkspaces {
            let shown = places.first { $0.workspace.id == workspace.id }
            let roots = shown?.repositories ?? savedRepositories(of: workspace)
            for root in roots { append(root: root, workspace: workspace) }
        }
        for path in Preference.recentRepositories.strings(defaults) {
            append(root: URL(fileURLWithPath: path, isDirectory: true), workspace: place.workspace)
        }
        return entries
    }

    private func bindTeleportNavigation() {
        teleport.onTeleport = { [weak self] destination in
            self?.palette?.close()
            self?.navigate(to: destination)
        }
    }

    func inspectTeleportInput(_ text: String) {
        bindTeleportNavigation()
        teleport.inspectPaletteInput(text, repositories: teleportRepositories())
    }

    func handleTeleportDeepLink(_ url: URL) -> Bool {
        bindTeleportNavigation()
        guard teleport.handleDeepLink(url, repositories: teleportRepositories()) else { return false }
        Task { @MainActor [weak self] in
            await self?.completeDeepLink()
        }
        return true
    }

    private func completeDeepLink() async {
        for _ in 0..<60 {
            if case .resolving = teleport.teleportPresenter.state {
                try? await Task.sleep(for: .milliseconds(50))
            } else {
                finishTeleportResolution()
                return
            }
        }
    }

    private func finishTeleportResolution() {
        switch teleport.teleportPresenter.state {
        case .resolved: teleport.teleportPresenter.confirmTeleport()
        case .ambiguous, .notFound, .failed: showCommandPalette()
        case .resolving, .idle: break
        }
    }

    func navigate(to destination: TeleportDestination) {
        if place.workspace.id != destination.workspaceID, workspaces[destination.workspaceID] != nil {
            openWorkspace(destination.workspaceID)
        }
        openRepositoryTab(destination.repoPath)
        showWindow()
        navigate(to: destination.target)
    }

    private func navigate(to target: TeleportTarget) {
        switch target {
        case .commit(let sha, _):
            model.section = .history
            repositoryController?.showCommit(id: sha)
        case .branch(let name):
            navigateToBranch(name)
        case .pullRequest, .workflowRun, .deployment:
            navigateToSignal(target)
        }
    }

    private func navigateToSignal(_ target: TeleportTarget) {
        switch target {
        case .pullRequest(let number, _, _, let url):
            model.section = .pullRequests
            openSignal(fallback: url) { $0.pullRequest?.number == number }
        case .workflowRun(let runID, _, _, _, let url):
            model.section = .workflows
            openWorkflowSignal(runID, fallback: url)
        case .deployment(let reference, _, let url):
            model.section = .deployments
            openDeploymentSignal(reference, fallback: url)
        default: break
        }
    }

    private func openDeploymentSignal(_ reference: String, fallback url: URL?) {
        openSignal(fallback: url) { $0.id == reference || $0.url?.absoluteString == reference }
    }

    private func openWorkflowSignal(_ runID: Int64, fallback url: URL?) {
        openSignal(fallback: url) {
            guard case .workflowRun(_, let id, _) = $0.target else { return false }
            return id == runID
        }
    }

    private func openSignal(fallback url: URL?, matching predicate: (ProviderItem) -> Bool) {
        if let match = model.allSignals.first(where: predicate) {
            repositoryController?.openProviderContext(match)
        } else if let url = Deck.safeWebURL(url) {
            Deck.open(url)
        }
    }

    private func navigateToBranch(_ name: String) {
        model.section = .history
        if let ref = model.snapshot?.references.first(where: {
            $0.name == name || $0.fullName == name || $0.fullName == "refs/heads/\(name)"
        }) {
            model.focusHistory(on: ref)
        }
    }
}
