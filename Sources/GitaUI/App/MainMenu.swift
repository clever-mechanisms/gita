import AppKit

/// The app's menu bar menus. The shell's own items target it (`AppDelegate`); the Git items are nil-targeted and reach
/// the selected tab's `RepositoryCommandResponder` through the responder chain. The shell validates them all.
@MainActor
struct MainMenu {
    private let main = NSMenu()
    private let target: AppDelegate

    static func build(target: AppDelegate) -> NSMenu {
        let builder = Self(target: target)
        builder.appMenu()
        builder.fileMenu()
        builder.editMenu()
        builder.viewMenu()
        builder.repositoryMenu()
        builder.branchMenu()
        builder.historyMenu()
        builder.agentsMenu()
        builder.windowMenu()
        return builder.main
    }

    private init(target: AppDelegate) { self.target = target }

    private func menu(_ title: String) -> NSMenu {
        let item = NSMenuItem()
        item.title = title
        let submenu = NSMenu(title: title)
        item.submenu = submenu
        main.addItem(item)
        return submenu
    }

    @discardableResult
    private func item(
        _ title: String, _ selector: Selector, key: String = "", in menu: NSMenu, symbol: String? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = target.responds(to: selector) ? target : nil
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        menu.addItem(item)
        return item
    }

    /// An item whose shortcut Settings ▸ Shortcuts sets (`ShortcutStore.apply`).
    @discardableResult
    private func item(
        _ command: ShortcutCommand, _ selector: Selector, in menu: NSMenu, symbol: String? = nil
    ) -> NSMenuItem {
        let item = item(command.title, selector, in: menu, symbol: symbol)
        item.identifier = command.menuIdentifier
        return item
    }

    /// A shortcut without a visible item.
    private func hiddenShortcut(_ title: String, _ selector: Selector, key: String, in menu: NSMenu) -> NSMenuItem {
        let shortcut = item(title, selector, key: key, in: menu)
        shortcut.isHidden = true
        shortcut.allowsKeyEquivalentWhenHidden = true
        return shortcut
    }

    private func appMenu() {
        let app = menu("Gitā")
        item(String(localized: "About Gitā"), #selector(AppDelegate.about), in: app, symbol: "info.circle")
        item(
            String(localized: "Check for Updates…"), #selector(AppDelegate.checkForUpdates), in: app,
            symbol: "arrow.down.circle")
        item(String(localized: "Setup Guide…"), #selector(AppDelegate.showSetupGuide), in: app, symbol: "checklist")
        app.addItem(.separator())
        item(String(localized: "Settings…"), #selector(AppDelegate.settings), key: ",", in: app, symbol: "gearshape")
        app.addItem(.separator())
        app.addItem(
            NSMenuItem(
                title: String(localized: "Hide Gitā"), action: #selector(NSApplication.hide(_:)),
                keyEquivalent: "h"))
        app.addItem(.separator())
        item(String(localized: "Quit Gitā"), #selector(AppDelegate.quit), key: "q", in: app, symbol: "power")
    }

    private func fileMenu() {
        let file = menu(String(localized: "File"))
        item(
            String(localized: "Open Repository…"), #selector(AppDelegate.openRepository), key: "o", in: file,
            symbol: "folder")
        item(String(localized: "New Tab"), #selector(AppDelegate.newTab), key: "t", in: file, symbol: "plus")
        item(
            String(localized: "Clone Repository…"), #selector(AppDelegate.cloneRepository), in: file,
            symbol: "square.and.arrow.down")
        item(
            String(localized: "New Repository…"), #selector(AppDelegate.initializeRepository), in: file,
            symbol: "folder.badge.plus")
        item(String(localized: "Open Recent"), #selector(AppDelegate.openRecent), in: file, symbol: "clock")
        file.addItem(.separator())
        // The workspaces, and New, Rename and Delete: listed afresh each time the menu opens (`WorkspaceMenu`).
        let workspace = NSMenuItem(title: String(localized: "Workspace"), action: nil, keyEquivalent: "")
        workspace.image = NSImage(systemSymbolName: Deck.workspaceSymbol, accessibilityDescription: nil)
        workspace.submenu = target.workspaceMenu.submenu(title: workspace.title)
        file.addItem(workspace)
        file.addItem(.separator())
        item(
            String(localized: "New Worktree…"), #selector(RepositoryCommandResponder.newWorktree), in: file,
            symbol: "arrow.triangle.branch")
        item(String(localized: "Close Tab"), #selector(AppDelegate.closeWindow), key: "w", in: file, symbol: "xmark")
        item(
            String(localized: "Close Window"), #selector(AppDelegate.closeEntireWindow), key: "w", in: file,
            symbol: "xmark.rectangle"
        ).keyEquivalentModifierMask = [.command, .shift]
    }

    private func editMenu() {
        let edit = menu(String(localized: "Edit"))
        for (title, action, key, symbol) in [
            (String(localized: "Undo"), NSSelectorFromString("undo:"), "z", "arrow.uturn.backward"),
            (String(localized: "Cut"), #selector(NSText.cut(_:)), "x", "scissors"),
            (String(localized: "Copy"), #selector(NSText.copy(_:)), "c", "doc.on.doc"),
            (String(localized: "Paste"), #selector(NSText.paste(_:)), "v", "doc.on.clipboard"),
            (String(localized: "Select All"), #selector(NSText.selectAll(_:)), "a", "checkmark.square"),
        ] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
            entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            edit.addItem(entry)
        }
        edit.addItem(.separator())
        item(
            String(localized: "Find in History"), #selector(AppDelegate.findInHistory), key: "f", in: edit,
            symbol: "magnifyingglass")
    }

    private func viewMenu() {
        let view = menu(String(localized: "View"))
        item(.commandPalette, #selector(AppDelegate.showCommandPalette), in: view, symbol: "magnifyingglass")
        view.addItem(.separator())
        // ⌥⌘1… for pages by default (⌘1…⌘9 choose repository tabs). Worktrees opens and closes the right-hand
        // Worktrees & Agents pane.
        for section in Section.workspaceSections {
            let pane = section == .worktrees
            let row = item(
                pane ? String(localized: "Worktrees & Agents") : section.localizedTitle,
                #selector(AppDelegate.navigate(_:)), in: view, symbol: pane ? "sidebar.right" : section.symbol)
            row.representedObject = section.rawValue
            row.identifier = ShortcutCommand.page(section)?.menuIdentifier
        }
        view.addItem(.separator())
        // The detail pane's tabs under the history: ⌃⌘1… by default.
        let detailItems: [(ShortcutCommand, String)] = [
            (.commitTab, "text.alignleft"),
            (.changesTab, "doc.text"),
            (.fileTreeTab, "list.bullet.indent"),
        ]
        for (tab, (command, symbol)) in zip(DetailTab.allCases, detailItems) {
            item(command, #selector(AppDelegate.showDetailTab(_:)), in: view, symbol: symbol).tag = tab.rawValue
        }
        item(.blame, #selector(AppDelegate.blameSelectedFile), in: view, symbol: "person.text.rectangle")
        view.addItem(.separator())
        item(
            String(localized: "Zoom In"), #selector(AppDelegate.zoomIn), key: "+", in: view,
            symbol: "plus.magnifyingglass")
        _ = hiddenShortcut(String(localized: "Zoom In"), #selector(AppDelegate.zoomIn), key: "=", in: view)
        item(
            String(localized: "Zoom Out"), #selector(AppDelegate.zoomOut), key: "-", in: view,
            symbol: "minus.magnifyingglass")
        item(
            String(localized: "Actual Size"), #selector(AppDelegate.actualSize), key: "0", in: view,
            symbol: "1.magnifyingglass")
        item(
            String(localized: "Show Commit Details"), #selector(AppDelegate.toggleHistoryDetails), key: "d", in: view,
            symbol: "rectangle.bottomthird.inset.filled")
        item(.toggleTerminal, #selector(AppDelegate.toggleTerminal), in: view, symbol: "apple.terminal")
        item(.newTerminal, #selector(AppDelegate.newTerminal), in: view, symbol: "plus.rectangle.on.rectangle")
        view.addItem(.separator())
        item(
            String(localized: "Show Menu Panel"), #selector(AppDelegate.togglePanel), key: "M", in: view,
            symbol: "menubar.rectangle")
    }

    private func repositoryMenu() {
        let repo = menu(String(localized: "Repository"))
        item(.refresh, #selector(AppDelegate.refresh), in: repo, symbol: "arrow.clockwise")
        repo.addItem(.separator())
        remoteItems(in: repo)
        repo.addItem(.separator())
        item(.stash, #selector(RepositoryCommandResponder.stash), in: repo, symbol: "archivebox")
        item(
            String(localized: "Organize into Commits"), #selector(AppDelegate.showCommitBuckets), in: repo,
            symbol: "square.stack.3d.forward.dottedline")
        item(.storage, #selector(AppDelegate.showStorageInspector), in: repo, symbol: "internaldrive")
        item(
            String(localized: "Submodules & Git LFS"), #selector(AppDelegate.showSubmodulesAndLFS), in: repo,
            symbol: "shippingbox")
        repo.addItem(.separator())
        item(
            String(localized: "Export Patch…"), #selector(AppDelegate.exportPatch), in: repo,
            symbol: "square.and.arrow.up")
        item(
            String(localized: "Apply Patch…"), #selector(AppDelegate.applyPatch), in: repo,
            symbol: "doc.badge.plus")
        repo.addItem(.separator())
        item(
            String(localized: "Open in External Diff Tool"), #selector(AppDelegate.openInExternalDiffTool), in: repo,
            symbol: "arrow.left.arrow.right.square")
        item(
            String(localized: "Open in External Merge Tool"), #selector(AppDelegate.openInExternalMergeTool), in: repo,
            symbol: "arrow.triangle.merge")
        item(
            String(localized: "Reveal in Finder"), #selector(RepositoryCommandResponder.reveal), in: repo,
            symbol: "folder")
    }

    private func remoteItems(in repo: NSMenu) {
        item(.fetch, #selector(RepositoryCommandResponder.fetch), in: repo, symbol: "arrow.down.to.line")
        item(.pull, #selector(RepositoryCommandResponder.pull), in: repo, symbol: "arrow.down")
        item(.push, #selector(RepositoryCommandResponder.push), in: repo, symbol: "arrow.up")
        item(
            .forcePush, #selector(RepositoryCommandResponder.forcePush), in: repo,
            symbol: "exclamationmark.arrow.triangle.2.circlepath")
        item(
            String(localized: "Manage Remotes…"), #selector(RepositoryCommandResponder.manageRemotes), in: repo,
            symbol: "externaldrive.connected.to.line.below")
        item(
            String(localized: "Open Remote in Browser"), #selector(RepositoryCommandResponder.openRemote), key: "G",
            in: repo, symbol: "globe")
    }

    private func branchMenu() {
        let branch = menu(String(localized: "Branch"))
        item(
            .switchBranch, #selector(RepositoryCommandResponder.switchBranch), in: branch,
            symbol: "arrow.triangle.branch")
        item(.newBranch, #selector(RepositoryCommandResponder.newBranch), in: branch, symbol: "plus.circle")
        item(
            String(localized: "Rename Branch…"), #selector(RepositoryCommandResponder.renameBranch(_:)), key: "R",
            in: branch, symbol: "pencil")
        item(
            String(localized: "Set Upstream…"), #selector(RepositoryCommandResponder.setBranchUpstream(_:)), in: branch,
            symbol: "arrow.up.arrow.down")
        item(
            String(localized: "Delete Local Branch…"), #selector(RepositoryCommandResponder.deleteBranch(_:)),
            in: branch,
            symbol: "trash")
        branch.addItem(.separator())
        item(
            String(localized: "Stacked Branches"), #selector(AppDelegate.showStackedBranches), in: branch,
            symbol: "square.stack.3d.up")
        item(
            String(localized: "Branch & Worktree Cleanup"), #selector(AppDelegate.showCleanupAssistant), in: branch,
            symbol: "wand.and.stars")
        branch.addItem(.separator())
        item(
            String(localized: "Merge…"), #selector(RepositoryCommandResponder.mergeBranch), in: branch,
            symbol: "arrow.triangle.merge")
        item(
            String(localized: "Rebase…"), #selector(RepositoryCommandResponder.rebaseBranch), in: branch,
            symbol: "arrow.triangle.pull")
        branch.addItem(.separator())
        item(
            String(localized: "Tag Selected Commit…"), #selector(RepositoryCommandResponder.createTag), in: branch,
            symbol: "tag")
        item(
            String(localized: "Delete Local Tag…"), #selector(RepositoryCommandResponder.deleteTag(_:)), in: branch,
            symbol: "tag.slash")
    }

    private func historyMenu() {
        let history = menu(String(localized: "History"))
        item(
            String(localized: "Edit Commits After Selection…"), #selector(RepositoryCommandResponder.editCommits),
            in: history, symbol: "slider.horizontal.3")
        item(
            String(localized: "Cherry-pick Selected Commit…"), #selector(RepositoryCommandResponder.cherryPickCommit),
            in: history, symbol: "arrow.uturn.right")
        item(
            String(localized: "Revert Selected Commit…"), #selector(RepositoryCommandResponder.revertCommit),
            in: history, symbol: "arrow.uturn.backward")
        item(
            String(localized: "Reset to Selected Commit…"), #selector(RepositoryCommandResponder.resetCommit),
            in: history, symbol: "arrow.counterclockwise")
        history.addItem(.separator())
        item(
            String(localized: "Continue Operation"), #selector(RepositoryCommandResponder.continueOperation),
            in: history, symbol: "play.fill")
        item(
            String(localized: "Skip Current Commit…"), #selector(RepositoryCommandResponder.skipOperation),
            in: history, symbol: "forward.end")
        item(
            String(localized: "Abort Operation…"), #selector(RepositoryCommandResponder.abortOperation),
            in: history, symbol: "xmark")
        history.addItem(.separator())
        item(
            String(localized: "Reflog"), #selector(AppDelegate.showReflogBrowser), in: history,
            symbol: "clock.arrow.circlepath")
        item(
            String(localized: "Search Code History"), #selector(AppDelegate.showCodeSearch), in: history,
            symbol: "doc.text.magnifyingglass")
        item(String(localized: "Start Git Bisect…"), #selector(AppDelegate.startBisect), in: history, symbol: "scope")
        history.addItem(.separator())
        item(
            String(localized: "Copy Selected Commit SHA"), #selector(RepositoryCommandResponder.copyCommit),
            in: history, symbol: "doc.on.doc")
        item(String(localized: "Copy Permalink"), #selector(AppDelegate.copyPermalink), in: history, symbol: "link")
    }

    private func agentsMenu() {
        let agents = menu(String(localized: "Agents"))
        item(
            String(localized: "Worktrees & Agents"), #selector(AppDelegate.showAgentsPane), in: agents,
            symbol: "sidebar.right")
        item(
            String(localized: "Collision Radar"), #selector(AppDelegate.showCollisionRadar), in: agents,
            symbol: "dot.radiowaves.left.and.right")
        item(
            String(localized: "Agent Flight Recorder"), #selector(AppDelegate.showAgentFlightRecorder), in: agents,
            symbol: "waveform.path.ecg")
        item(
            String(localized: "Fork & Race Arena"), #selector(AppDelegate.showAgentArena), in: agents,
            symbol: "flag.checkered.2.crossed")
    }

    private func windowMenu() {
        let window = menu(String(localized: "Window"))
        NSApp.windowsMenu = window
        item(
            String(localized: "Select Next Tab"), #selector(AppDelegate.nextTab), key: "]", in: window,
            symbol: "chevron.right.square"
        ).keyEquivalentModifierMask = [.command, .shift]
        item(
            String(localized: "Select Previous Tab"), #selector(AppDelegate.previousTab), key: "[", in: window,
            symbol: "chevron.left.square"
        ).keyEquivalentModifierMask = [.command, .shift]
        let tabShortcuts: [(Selector, NSEvent.ModifierFlags)] = [
            (#selector(AppDelegate.nextTab), .control), (#selector(AppDelegate.previousTab), [.control, .shift]),
        ]
        for (action, modifiers) in tabShortcuts {
            hiddenShortcut(String(localized: "Switch Tab"), action, key: "\t", in: window).keyEquivalentModifierMask =
                modifiers
        }
        // ⌘1…⌘8 choose that tab, ⌘9 the last (as in Safari); the tab tooltips show each number.
        for number in MainMenuTabs.numbers {
            let title =
                number == MainMenuTabs.last
                ? String(localized: "Select Last Tab") : String(localized: "Select Tab \(number)")
            hiddenShortcut(title, #selector(AppDelegate.selectTabNumber(_:)), key: String(number), in: window).tag =
                number
        }
        window.addItem(.separator())
        item(
            String(localized: "Activity"), #selector(AppDelegate.showActivity), key: "a", in: window,
            symbol: "waveform.path"
        ).keyEquivalentModifierMask = [.command, .shift]
        item(
            String(localized: "Workspace Command Center"), #selector(AppDelegate.showWorkspaceCommandCenter),
            in: window, symbol: "square.grid.2x2")
        item(
            String(localized: "Workspace Storage…"), #selector(AppDelegate.showWorkspaceStorage),
            in: window, symbol: "internaldrive")
        window.addItem(.separator())
        let minimize = NSMenuItem(
            title: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m")
        minimize.image = NSImage(systemSymbolName: "minus.square", accessibilityDescription: nil)
        window.addItem(minimize)
        item(String(localized: "Show Gitā"), #selector(AppDelegate.showWindow), in: window, symbol: "macwindow")
    }
}
