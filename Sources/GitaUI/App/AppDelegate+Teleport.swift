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
        Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<60 {
                switch self.teleport.teleportPresenter.state {
                case .resolving:
                    try? await Task.sleep(for: .milliseconds(50))
                case .resolved:
                    self.teleport.teleportPresenter.confirmTeleport()
                    return
                case .ambiguous, .notFound, .failed:
                    self.showCommandPalette()
                    return
                case .idle:
                    return
                }
            }
        }
        return true
    }

    func navigate(to destination: TeleportDestination) {
        if place.workspace.id != destination.workspaceID, workspaces[destination.workspaceID] != nil {
            openWorkspace(destination.workspaceID)
        }
        openRepositoryTab(destination.repoPath)
        showWindow()
        switch destination.target {
        case .commit(let sha, _):
            model.section = .history
            repositoryController?.showCommit(id: sha)
        case .pullRequest(let number, _, _, let url):
            model.section = .pullRequests
            if let match = model.allSignals.first(where: { $0.pullRequest?.number == number }) {
                repositoryController?.openProviderContext(match)
            } else if let url = Deck.safeWebURL(url) {
                Deck.open(url)
            }
        case .workflowRun(let runID, _, _, _, let url):
            model.section = .workflows
            if let match = model.allSignals.first(where: {
                if case .workflowRun(_, let id, _) = $0.target { return id == runID }
                return false
            }) {
                repositoryController?.openProviderContext(match)
            } else if let url = Deck.safeWebURL(url) {
                Deck.open(url)
            }
        case .deployment(let reference, _, let url):
            model.section = .deployments
            if let match = model.allSignals.first(where: {
                $0.id == reference || $0.url?.absoluteString == reference
            }) {
                repositoryController?.openProviderContext(match)
            } else if let url = Deck.safeWebURL(url) {
                Deck.open(url)
            }
        case .branch(let name):
            model.section = .history
            if let ref = model.snapshot?.references.first(where: {
                $0.name == name || $0.fullName == name || $0.fullName == "refs/heads/\(name)"
            }) {
                model.focusHistory(on: ref)
            }
        }
    }
}
