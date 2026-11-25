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
        item(String(localized: "About Gitā"), #selector(AppDelegate.about), in: app)
        item(String(localized: "Setup Guide…"), #selector(AppDelegate.showSetupGuide), in: app)
        app.addItem(.separator())
        item(String(localized: "Settings…"), #selector(AppDelegate.settings), key: ",", in: app)
        app.addItem(.separator())
        app.addItem(
            NSMenuItem(
                title: String(localized: "Hide Gitā"), action: #selector(NSApplication.hide(_:)),
                keyEquivalent: "h"))
        app.addItem(.separator())
        item(String(localized: "Quit Gitā"), #selector(AppDelegate.quit), key: "q", in: app)
    }

    private func fileMenu() {
        let file = menu(String(localized: "File"))
        item(
            String(localized: "Open Repository…"), #selector(AppDelegate.openRepository), key: "o", in: file,
            symbol: "folder")
        item(String(localized: "New Tab"), #selector(AppDelegate.newTab), key: "t", in: file, symbol: "plus")
        item(String(localized: "Clone Repository…"), #selector(AppDelegate.cloneRepository), in: file)
        item(String(localized: "New Repository…"), #selector(AppDelegate.initializeRepository), in: file)
        item(String(localized: "Open Recent"), #selector(AppDelegate.openRecent), in: file)
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
        item(String(localized: "Close Tab"), #selector(AppDelegate.closeWindow), key: "w", in: file)
        item(String(localized: "Close Window"), #selector(AppDelegate.closeEntireWindow), key: "w", in: file)
            .keyEquivalentModifierMask = [.command, .shift]
    }

    private func editMenu() {
        let edit = menu(String(localized: "Edit"))
        for (title, action, key) in [
            (String(localized: "Undo"), Selector(("undo:")), "z"),
            (String(localized: "Cut"), #selector(NSText.cut(_:)), "x"),
            (String(localized: "Copy"), #selector(NSText.copy(_:)), "c"),
            (String(localized: "Paste"), #selector(NSText.paste(_:)), "v"),
            (String(localized: "Select All"), #selector(NSText.selectAll(_:)), "a"),
        ] { edit.addItem(NSMenuItem(title: title, action: action, keyEquivalent: key)) }
        edit.addItem(.separator())
        item(String(localized: "Find in History"), #selector(AppDelegate.findInHistory), key: "f", in: edit)
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
        for (tab, command) in zip(DetailTab.allCases, [ShortcutCommand.commitTab, .changesTab, .fileTreeTab]) {
            item(command, #selector(AppDelegate.showDetailTab(_:)), in: view).tag = tab.rawValue
        }
        item(.blame, #selector(AppDelegate.blameSelectedFile), in: view)
        view.addItem(.separator())
        item(String(localized: "Zoom In"), #selector(AppDelegate.zoomIn), key: "+", in: view)
        _ = hiddenShortcut(String(localized: "Zoom In"), #selector(AppDelegate.zoomIn), key: "=", in: view)
        item(String(localized: "Zoom Out"), #selector(AppDelegate.zoomOut), key: "-", in: view)
        item(String(localized: "Actual Size"), #selector(AppDelegate.actualSize), key: "0", in: view)
        item(String(localized: "Show Commit Details"), #selector(AppDelegate.toggleHistoryDetails), key: "d", in: view)
        item(.toggleTerminal, #selector(AppDelegate.toggleTerminal), in: view, symbol: "apple.terminal")
        item(.newTerminal, #selector(AppDelegate.newTerminal), in: view, symbol: "plus.rectangle.on.rectangle")
        view.addItem(.separator())
        item(String(localized: "Show Menu Panel"), #selector(AppDelegate.togglePanel), key: "M", in: view)
    }

    private func repositoryMenu() {
        let repo = menu(String(localized: "Repository"))
        item(.refresh, #selector(AppDelegate.refresh), in: repo, symbol: "arrow.clockwise")
        repo.addItem(.separator())
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
            in: repo,
            symbol: "globe")
        repo.addItem(.separator())
        branchItems(in: repo)
        repo.addItem(.separator())
        operationItems(in: repo)
        repo.addItem(.separator())
        item(String(localized: "Copy Selected Commit SHA"), #selector(RepositoryCommandResponder.copyCommit), in: repo)
        item(
            String(localized: "Reveal in Finder"), #selector(RepositoryCommandResponder.reveal), in: repo,
            symbol: "folder")
    }

    private func branchItems(in repo: NSMenu) {
        item(
            .switchBranch, #selector(RepositoryCommandResponder.switchBranch), in: repo, symbol: "arrow.triangle.branch"
        )
        item(.newBranch, #selector(RepositoryCommandResponder.newBranch), in: repo)
        item(.stash, #selector(RepositoryCommandResponder.stash), in: repo, symbol: "archivebox")
        item(
            String(localized: "Rename Branch…"), #selector(RepositoryCommandResponder.renameBranch(_:)), key: "R",
            in: repo)
        item(String(localized: "Set Upstream…"), #selector(RepositoryCommandResponder.setBranchUpstream(_:)), in: repo)
        item(
            String(localized: "Delete Local Branch…"), #selector(RepositoryCommandResponder.deleteBranch(_:)), in: repo)
        repo.addItem(.separator())
        item(
            String(localized: "Tag Selected Commit…"), #selector(RepositoryCommandResponder.createTag), in: repo,
            symbol: "tag")
        item(String(localized: "Delete Local Tag…"), #selector(RepositoryCommandResponder.deleteTag(_:)), in: repo)
    }

    private func operationItems(in repo: NSMenu) {
        item(
            String(localized: "Merge…"), #selector(RepositoryCommandResponder.mergeBranch), in: repo,
            symbol: "arrow.triangle.merge")
        item(
            String(localized: "Rebase…"), #selector(RepositoryCommandResponder.rebaseBranch), in: repo,
            symbol: "arrow.triangle.branch")
        item(
            String(localized: "Edit Commits After Selection…"), #selector(RepositoryCommandResponder.editCommits),
            in: repo)
        item(
            String(localized: "Cherry-pick Selected Commit…"), #selector(RepositoryCommandResponder.cherryPickCommit),
            in: repo)
        item(String(localized: "Revert Selected Commit…"), #selector(RepositoryCommandResponder.revertCommit), in: repo)
        item(
            String(localized: "Reset to Selected Commit…"), #selector(RepositoryCommandResponder.resetCommit), in: repo)
        item(
            String(localized: "Continue Operation"), #selector(RepositoryCommandResponder.continueOperation), in: repo,
            symbol: "play.fill")
        item(
            String(localized: "Skip Current Commit…"), #selector(RepositoryCommandResponder.skipOperation), in: repo,
            symbol: "forward.end")
        item(
            String(localized: "Abort Operation…"), #selector(RepositoryCommandResponder.abortOperation), in: repo,
            symbol: "xmark")
    }

    private func windowMenu() {
        let window = menu(String(localized: "Window"))
        NSApp.windowsMenu = window
        item(String(localized: "Select Next Tab"), #selector(AppDelegate.nextTab), key: "]", in: window)
            .keyEquivalentModifierMask = [.command, .shift]
        item(String(localized: "Select Previous Tab"), #selector(AppDelegate.previousTab), key: "[", in: window)
            .keyEquivalentModifierMask = [.command, .shift]
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
        item(String(localized: "Activity"), #selector(AppDelegate.showActivity), key: "a", in: window)
            .keyEquivalentModifierMask = [.command, .shift]
        window.addItem(.separator())
        window.addItem(
            NSMenuItem(
                title: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)),
                keyEquivalent: "m"))
        item(String(localized: "Show Gitā"), #selector(AppDelegate.showWindow), in: window)
    }
}
