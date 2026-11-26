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

    func inspectTeleportInput(_ text: String) {
        teleport.onTeleport = { [weak self] destination in
            self?.palette?.close()
            self?.navigate(to: destination)
        }
        teleport.inspectPaletteInput(text, repositories: teleportRepositories())
    }

    func handleTeleportDeepLink(_ url: URL) -> Bool {
        teleport.onTeleport = { [weak self] destination in
            self?.palette?.close()
            self?.navigate(to: destination)
        }
        guard teleport.handleDeepLink(url, repositories: teleportRepositories()) else { return false }
        Task { @MainActor [weak self] in await self?.awaitTeleportDeepLinkResolution() }
        return true
    }

    private func awaitTeleportDeepLinkResolution() async {
        for _ in 0..<60 {
            if !stepTeleportResolution() { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func stepTeleportResolution() -> Bool {
        if case .resolving = teleport.teleportPresenter.state { return true }
        finishTeleportResolution()
        return false
    }

    private func finishTeleportResolution() {
        switch teleport.teleportPresenter.state {
        case .resolved:
            teleport.teleportPresenter.confirmTeleport()
        case .ambiguous, .notFound, .failed:
            showCommandPalette()
        case .idle, .resolving:
            break
        }
    }

    func navigate(to destination: TeleportDestination) {
        if place.workspace.id != destination.workspaceID, workspaces[destination.workspaceID] != nil {
            openWorkspace(destination.workspaceID)
        }
        openRepositoryTab(destination.repoPath)
        showWindow()
        navigateTarget(destination.target)
    }

    private func navigateTarget(_ target: TeleportTarget) {
        switch target {
        case .commit(let sha, _):
            model.section = .history
            repositoryController?.showCommit(id: sha)
        case .branch(let name):
            focusBranch(named: name)
        case .pullRequest, .workflowRun, .deployment:
            navigateProviderTarget(target)
        }
    }

    private func navigateProviderTarget(_ target: TeleportTarget) {
        if case .pullRequest(let number, _, _, let url) = target {
            openProviderSection(.pullRequests, fallbackURL: url) { $0.pullRequest?.number == number }
            return
        }
        navigateRunOrDeploymentTarget(target)
    }

    private func navigateRunOrDeploymentTarget(_ target: TeleportTarget) {
        if case .workflowRun(let runID, _, _, _, let url) = target {
            openProviderSection(.workflows, fallbackURL: url) { $0.matchesWorkflowRun(runID) }
        } else if case .deployment(let reference, _, let url) = target {
            openProviderSection(.deployments, fallbackURL: url) { $0.matchesDeployment(reference) }
        }
    }

    private func openProviderSection(
        _ section: Section, fallbackURL: URL?, matching predicate: (ProviderItem) -> Bool
    ) {
        model.section = section
        if let match = model.allSignals.first(where: predicate) {
            repositoryController?.openProviderContext(match)
        } else if let url = Deck.safeWebURL(fallbackURL) {
            Deck.open(url)
        }
    }

    private func focusBranch(named name: String) {
        model.section = .history
        let ref = model.snapshot?.references.first {
            $0.name == name || $0.fullName == name || $0.fullName == "refs/heads/\(name)"
        }
        if let ref { model.focusHistory(on: ref) }
    }
}

extension ProviderItem {
    fileprivate func matchesWorkflowRun(_ runID: Int64) -> Bool {
        if case .workflowRun(_, let id, _) = target { return id == runID }
        return false
    }

    fileprivate func matchesDeployment(_ reference: String) -> Bool {
        id == reference || url?.absoluteString == reference
    }
}
