import AppKit
import GitaCore

/// What the main window's toolbar needs from the app shell: the active model, validation, the selected tab's
/// commands and the panes it toggles.
@MainActor
protocol MainToolbarHost: NSToolbarItemValidation {
    var model: AppModel { get }
    var commands: RepositoryCommandResponder { get }
    func toggleRepositorySidebar()
    func toggleAgentsPane()
    func showAgentsPane()
    /// File ▸ Workspace: switch, New, Rename and Delete.
    func workspaceSwitcherMenu() -> NSMenu?
    func pillDropOperation(for pasteboard: NSPasteboard) -> NSDragOperation
    func performPillDrop(from pasteboard: NSPasteboard, anchor: NSView) -> Bool
}

/// Each repository tab's Git commands live in its own `RepositoryCommandResponder`. The selected tab's (the resting
/// model's while no window is open) follows the application in the responder chain, so the menus' nil-targeted Git
/// items reach it whichever window is key, and its tab view sends its menus' commands to it.
extension AppDelegate: RepositoryCommandHost, MainToolbarHost, SettingsShell {
    /// The selected tab's commands.
    var commands: RepositoryCommandResponder { commands(for: model) }

    func commands(for model: AppModel) -> RepositoryCommandResponder {
        let key = ObjectIdentifier(model)
        if let responder = commandResponders[key] { return responder }
        let responder = RepositoryCommandResponder(model: model, host: self)
        commandResponders[key] = responder
        return responder
    }

    /// `model` became the active one: its commands join the responder chain; those of closed tabs are dropped.
    func activateCommands(for model: AppModel) {
        let open = [model] + places.flatMap(\.models)
        let kept = Set(open.map(ObjectIdentifier.init))
        commandResponders = commandResponders.filter { kept.contains($0.key) }
        let responder = commands(for: model)
        NSApp.nextResponder = responder
        repositoryController?.commands = responder
        installPaneFocusMenuItemsIfNeeded(in: NSApp.mainMenu)
        installAgentControlMenuItemsIfNeeded(in: NSApp.mainMenu)
        wireAgentControlHooks()
    }

    func installPaneFocusMenuItemsIfNeeded(in menu: NSMenu?) {
        guard let viewMenu = menu?.item(withTitle: String(localized: "View"))?.submenu else { return }
        let entries: [(ShortcutCommand, Selector)] = [
            (.focusSidebar, #selector(Self.focusSidebar)),
            (.focusHistory, #selector(Self.focusHistory)),
            (.focusFiles, #selector(Self.focusFiles)),
            (.focusDiff, #selector(Self.focusDiff)),
            (.cyclePaneFocus, #selector(Self.cyclePaneFocus)),
        ]
        var inserted = false
        for (command, action) in entries {
            let identifier = command.menuIdentifier
            guard !viewMenu.items.contains(where: { $0.identifier == identifier }) else { continue }
            let item = NSMenuItem(title: command.title, action: action, keyEquivalent: "")
            item.target = self
            item.identifier = identifier
            item.isHidden = true
            item.allowsKeyEquivalentWhenHidden = true
            viewMenu.addItem(item)
            inserted = true
        }
        if inserted { ShortcutStore.apply(to: viewMenu, defaults) }
    }

    /// The chain must not keep a responder this shell no longer owns (`nextResponder` does not retain it).
    func deactivateCommands() {
        cleanupAgentControlOnTerminate()
        if let next = NSApp.nextResponder as? RepositoryCommandResponder, next.host === self {
            NSApp.nextResponder = nil
        }
    }

    /// Text fields in a sheet on the main window (shown first); `action` gets the values when confirmed.
    func prompt(
        _ title: String, labels: [String], defaults values: [String], button: String = String(localized: "Create"),
        action: @escaping @MainActor ([String]) -> Void
    ) {
        showWindow()
        guard let mainWindow else { return }
        let rows = zip(labels, values).map { RepositoryPrompts.Field(label: $0, value: $1) }
        RepositoryPrompts.fields(
            title, rows, button: button, on: mainWindow, alerts: environment.system.alerts, action: action)
    }

    func pillDropOperation(for pasteboard: NSPasteboard) -> NSDragOperation {
        repositoryController?.pillDropOperation(for: pasteboard.pasteboardItems ?? []) ?? []
    }

    func performPillDrop(from pasteboard: NSPasteboard, anchor: NSView) -> Bool {
        repositoryController?.handlePillDrop(items: pasteboard.pasteboardItems ?? [], anchor: anchor) ?? false
    }
}
