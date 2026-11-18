import AppKit

/// The Workspace menu: File ▸ Workspace in the menu bar and the button that leads a window's tab bar. Its items are
/// asked for each time it opens, so it always lists the workspaces as they are.
@MainActor
final class WorkspaceMenu: NSObject, NSMenuDelegate {
    /// What the menu shows now (`AppDelegate.workspaceMenuItems`).
    var items: () -> [NSMenuItem] = { [] }

    /// A menu filled now, to pop up under the tab bar's button.
    func menu() -> NSMenu {
        let menu = NSMenu()
        fill(menu)
        return menu
    }

    /// A submenu that refills itself whenever it opens.
    func submenu(title: String) -> NSMenu {
        let menu = NSMenu(title: title)
        menu.delegate = self
        fill(menu)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) { fill(menu) }

    private func fill(_ menu: NSMenu) {
        menu.autoenablesItems = false // MenuAction targets itself: autoenabling would turn a dimmed item back on
        menu.removeAllItems()
        items().forEach(menu.addItem)
    }

    /// The workspaces (the shown one checked, those open in another window marked), then New, Rename and Delete.
    struct Content {
        struct Row: Equatable {
            var id: String
            var title: String
            var isShown: Bool
            var hasWindow: Bool
        }

        var rows: [Row]
        /// The workspace Rename and Delete act on: the one in the front window.
        var shownTitle: String
        var canChange: Bool
        var canDelete: Bool

        init(list: WorkspaceList, shown: String, windowed: Set<String>, canChange: Bool) {
            rows = list.workspaces.map {
                Row(id: $0.id, title: $0.title, isShown: $0.id == shown, hasWindow: windowed.contains($0.id))
            }
            shownTitle = list[shown]?.title ?? ""
            self.canChange = canChange
            canDelete = canChange && list.canRemove
        }
    }

    /// The commands the menu's items run.
    struct Actions {
        var open: (String) -> Void
        var new: () -> Void
        var rename: () -> Void
        var delete: () -> Void
    }

    static func items(_ content: Content, actions: Actions) -> [NSMenuItem] {
        var items: [NSMenuItem] = content.rows.map { row in
            let item = MenuAction(row.title, symbol: row.hasWindow && !row.isShown ? "macwindow" : nil) {
                actions.open(row.id)
            }
            item.identifier = NSUserInterfaceItemIdentifier("workspace.\(row.id)")
            item.state = row.isShown ? .on : .off
            item.isEnabled = row.isShown || row.hasWindow || content.canChange
            return item
        }
        items.append(.separator())
        let new = MenuAction(String(localized: "New Workspace…"), symbol: "plus", handler: actions.new)
        let rename = MenuAction(String(localized: "Rename “\(content.shownTitle)”…"), handler: actions.rename)
        let delete = MenuAction(String(localized: "Delete “\(content.shownTitle)”…"), handler: actions.delete)
        new.isEnabled = content.canChange
        rename.isEnabled = content.canChange
        delete.isEnabled = content.canDelete
        return items + [new, rename, delete]
    }
}
