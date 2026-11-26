import AppKit
import GitaCore

/// The menus of repository and checkout rows (sidebar, reference menus) and what they open or remove.
extension RepositoryViewController {
    /// Agents listed in one checkout's menu.
    private static let listedAgents = 20

    /// A repository row: its main checkout's actions, then Remove from List (only the list entry goes; nothing on
    /// disk). A repository open in a tab here (itself or one of its worktrees) stays listed while the tab is open.
    func repositoryMenu(_ repository: RepositorySidebarView.Repository) -> NSMenu? {
        let menu = checkoutMenu(path: repository.root.path, isMain: true) ?? NSMenu()
        let paths = [repository.root.path] + repository.checkouts.map(\.path)
        let open = Set(
            (tabs?.openRepositories ?? []).compactMap { WindowAgents.key($0) })
        let isOpen =
            repository.isCurrent
            || paths.contains { WindowAgents.key(URL(fileURLWithPath: $0)).map(open.contains) == true }
        menu.autoenablesItems = false // MenuAction targets itself: autoenabling would turn the item back on
        menu.addItem(.separator())
        let remove = MenuAction(String(localized: "Remove from List"), symbol: "minus.circle") { [weak self] in
            self?.commands?.removeFromRepositoryList(paths)
        }
        remove.isEnabled = !isOpen
        if isOpen { remove.toolTip = String(localized: "Close its tab first") }
        menu.addItem(remove)
        return menu
    }

    func checkoutMenu(path: String, isMain: Bool) -> NSMenu? {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let menu = NSMenu()
        menu.addItem(
            MenuAction(String(localized: "Open in Tab"), symbol: "macwindow") { [weak self] in
                self?.commands?.openRepositoryTab(url)
            })
        menu.addItem(MenuAction(String(localized: "Reveal in Finder"), symbol: "folder") { OpenIn.finder(url) })
        menu.addItem(
            MenuAction(String(localized: "Open in Terminal"), symbol: "apple.terminal") { OpenIn.terminal(url) })
        menu.addItem(
            MenuAction(String(localized: "Inspect Storage & Health…"), symbol: "internaldrive") { [weak self] in
                self?.commands?.inspectStorage(at: url)
            })
        menu.addItem(remoteItem(url))
        if let custom = customActionSubmenu(scope: .worktree, worktreePath: url) { menu.addItem(custom) }
        if let agents = agentsItem(url) { menu.addItem(agents) }
        if !isMain,
            let tree = model.snapshot?.worktrees.first(where: {
                WindowAgents.key(URL(fileURLWithPath: $0.path)) == WindowAgents.key(url)
            })
        {
            menu.addItem(.separator())
            let remove = MenuAction(String(localized: "Remove Worktree…"), symbol: "trash") { [weak self] in
                self?.removeWorktree(tree)
            }
            remove.isEnabled = !tree.isLocked && !model.isMutating
            menu.addItem(remove)
        }
        return menu
    }

    /// Open on the remote's host: this window's checkout names its host; another repository's remote is read when
    /// the item is chosen.
    private func remoteItem(_ url: URL) -> NSMenuItem {
        let known = model.snapshot.flatMap {
            WindowAgents.key($0.root) == WindowAgents.key(url) ? RemotePage.repository($0) : nil
        }
        let title =
            known.map { String(localized: "Open on \(RemoteWebPage.hostName(of: $0))") }
            ?? String(localized: "Open Remote in Browser")
        return MenuAction(title, symbol: "globe") {
            if let known {
                Deck.open(known)
                return
            }
            Task { @MainActor in
                guard let page = await RemotePage.repository(remote: await GitService(root: url).defaultRemoteURL())
                else {
                    NSSound.beep()
                    return
                }
                Deck.open(page)
            }
        }
    }

    /// Bring the agent's terminal forward; several agents in one checkout are named so the right one comes forward.
    private func agentsItem(_ url: URL) -> NSMenuItem? {
        let here = WindowAgents.shared.sessions(checkout: url)
        let lead = here.filter { !$0.isSubagent }
        let agents = lead.isEmpty ? here : lead
        if agents.count == 1, let session = agents.first {
            return MenuAction(WindowAgents.shared.revealTitle(session), symbol: "macwindow.on.rectangle") {
                WindowAgents.shared.reveal(session)
            }
        }
        guard let first = agents.first else { return nil }
        let item = NSMenuItem(title: WindowAgents.shared.revealTitle(first), action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: nil)
        let submenu = NSMenu()
        for session in agents.prefix(Self.listedAgents) {
            submenu.addItem(
                MenuAction(WindowAgents.menuLine(session), symbol: nil) { WindowAgents.shared.reveal(session) })
        }
        item.submenu = submenu
        return item
    }

    /// Opens `remote/branch` on its host: the branch page where the host has one, else the repository page.
    func openRemoteBranch(_ remoteRef: String) {
        guard let service = model.service, let slash = remoteRef.firstIndex(of: "/") else {
            NSSound.beep()
            return
        }
        let remote = String(remoteRef[..<slash])
        let branch = String(remoteRef[remoteRef.index(after: slash)...])
        Task { @MainActor in
            let url = await service.remoteURL(named: remote)
            guard let page = await RemotePage.branch(remote: url, branch: branch) else {
                NSSound.beep()
                return
            }
            Deck.open(page)
        }
    }

    func removeWorktree(_ tree: GitWorktree) {
        guard let snapshot = model.snapshot, let service = model.service, !model.isMutating,
            snapshot.worktrees.contains(tree), tree.path != snapshot.root.path, !tree.isLocked, !tree.isBare,
            !tree.isPrunable, let window = view.window, window.attachedSheet == nil
        else { return }
        let agents = model.allSignals.filter {
            $0.kind == .agent && $0.state == .running && $0.worktreePath == tree.path
        }
        let activity = DestructiveConfirmation.workingAgentsNote(agents.map { $0.agent?.agentName ?? $0.title })
        let confirmation = DestructiveConfirmation(
            message: String(localized: "Remove worktree?"),
            detail: tree.path + (activity.map { "\n\n" + $0 } ?? ""), action: String(localized: "Remove"))
        confirmation.present(on: window) { [weak self] in
            _ = self?.performConfirmedWorktreeRemoval(tree, expectedService: service, repositoryRoot: snapshot.root)
        }
    }

    /// Runs a worktree removal that the user already confirmed (from either the main window or Storage window).
    func performConfirmedWorktreeRemoval(
        _ tree: GitWorktree, expectedService: GitService? = nil, repositoryRoot: URL
    ) -> Bool {
        guard let snapshot = model.snapshot, let service = model.service, !model.isMutating,
            expectedService == nil || service === expectedService,
            snapshot.worktrees.contains(tree), tree.path != snapshot.root.path, !tree.isLocked, !tree.isBare,
            !tree.isPrunable
        else { return false }
        model.perform(
            String(localized: "Remove worktree"),
            onSuccess: { [weak self] in
                self?.commands?.invalidateStorage(repositoryRoot: repositoryRoot)
            },
            operation: { current in
                let latest = try await current.snapshot(limit: 1)
                guard latest.worktrees.contains(tree), latest.root.path != tree.path else {
                    throw StaleStateError.worktreeChanged
                }
                try await current.removeWorktree(path: URL(fileURLWithPath: tree.path))
            })
        return true
    }
}
