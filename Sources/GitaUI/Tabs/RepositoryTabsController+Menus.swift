import AppKit
import GitaCore

/// The context menus of tabs and group chips.
extension RepositoryTabsController {
    private enum Step {
        static let left = -1
        static let right = 1
    }

    private func colorMenu(selected: TabColor?, allowsNone: Bool, choose: @escaping (TabColor?) -> Void) -> NSMenu {
        let menu = NSMenu()
        if allowsNone {
            let none = MenuAction(String(localized: "No Color")) { choose(nil) }
            none.state = selected == nil ? .on : .off
            menu.addItem(none)
            menu.addItem(.separator())
        }
        for color in TabColor.allCases {
            let item = MenuAction(color.localizedTitle) { choose(color) }
            item.image = color.swatch
            item.state = selected == color ? .on : .off
            menu.addItem(item)
        }
        return menu
    }
    /// Move Left and Move Right (a tab or group can also be dragged along the strip); dimmed at either end.
    private func addMoveItems(to menu: NSMenu, can: (Int) -> Bool, move: @escaping (Int) -> Void) {
        for (title, symbol, step) in [
            (String(localized: "Move Left"), "arrow.left", Step.left),
            (String(localized: "Move Right"), "arrow.right", Step.right),
        ] {
            let item = MenuAction(title, symbol: symbol) { move(step) }
            item.isEnabled = can(step)
            menu.addItem(item)
        }
    }
    private static func submenu(_ title: String, symbol: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        item.submenu = menu
        return item
    }

    /// Right-click on a tab: its colour, silencing its notifications, its group, moving it, and closing it.
    func menu(for tab: Tab) -> NSMenu {
        let menu = NSMenu()
        let colors = colorMenu(selected: tab.color, allowsNone: true) { [weak self, weak tab] color in
            guard let self, let tab else { return }
            self.setColor(color, of: tab)
        }
        menu.addItem(Self.submenu(String(localized: "Tab Color"), symbol: "paintpalette", colors))
        menu.addItem(silenceItem(for: tab))
        menu.addItem(.separator())
        addGroupItems(for: tab, to: menu)
        menu.addItem(.separator())
        let index = index(of: tab) ?? 0
        let items = reorderItems
        let groupIDs = list.groupIDs
        addMoveItems(
            to: menu, can: { TabReorder.stepTab(index, by: $0, groups: groupIDs, items: items) != nil },
            move: { [weak self, weak tab] step in
                if let self, let tab { self.step(tab, by: step) }
            })
        menu.addItem(.separator())
        let close = MenuAction(String(localized: "Close Tab")) { [weak self, weak tab] in
            guard let self, let tab, let index = self.index(of: tab) else { return }
            self.close(at: index)
        }
        close.isEnabled = canChangeRepository && !tab.model.isMutating
        menu.addItem(close)
        menu.autoenablesItems = false
        return menu
    }
    /// Silences (or allows again) the GitHub, Vercel and agent notifications of the tab's repository.
    private func silenceItem(for tab: Tab) -> NSMenuItem {
        let silenced = tab.root.map(environment.isSilenced) ?? false
        let item = MenuAction(
            silenced ? String(localized: "Allow Notifications") : String(localized: "Silence Notifications"),
            symbol: silenced ? "bell" : "bell.slash"
        ) { [weak self, weak tab] in
            guard let self, let root = tab?.root else { return }
            self.environment.setSilenced(root, !silenced)
            self.refreshTabs()
        }
        item.isEnabled = tab.root != nil
        return item
    }
    private func addGroupItems(for tab: Tab, to menu: NSMenu) {
        menu.addItem(
            MenuAction(String(localized: "Add to New Group…"), symbol: "rectangle.stack.badge.plus") {
                [weak self, weak tab] in
                guard let self, let tab else { return }
                self.addToNewGroup(tab)
            })
        let current = groupID(of: tab)
        let others = list.groups.filter { $0.id != current }
        if !others.isEmpty {
            let submenu = NSMenu()
            for group in others {
                let item = MenuAction(group.displayName) { [weak self, weak tab] in
                    guard let self, let tab, self.list.group(group.id) != nil else { return }
                    self.move(tab, into: group.id)
                }
                item.image = group.color.swatch
                submenu.addItem(item)
            }
            menu.addItem(Self.submenu(String(localized: "Add to Group"), symbol: "rectangle.stack", submenu))
        }
        if current != nil {
            menu.addItem(
                MenuAction(String(localized: "Remove from Group"), symbol: "rectangle.stack.badge.minus") {
                    [weak self, weak tab] in
                    guard let self, let tab else { return }
                    self.removeFromGroup(tab)
                })
        }
    }
    /// Right-click on a group's chip.
    func groupMenu(_ id: UUID) -> NSMenu? {
        guard let group = list.group(id) else { return nil }
        let menu = NSMenu()
        menu.addItem(
            MenuAction(String(localized: "Rename Group…"), symbol: "pencil") { [weak self] in self?.renameGroup(id) })
        let colors = colorMenu(selected: group.color, allowsNone: false) { [weak self] color in
            if let color { self?.setGroupColor(color, of: id) }
        }
        menu.addItem(Self.submenu(String(localized: "Group Color"), symbol: "paintpalette", colors))
        menu.addItem(
            MenuAction(
                group.collapsed ? String(localized: "Expand Group") : String(localized: "Collapse Group"),
                symbol: group.collapsed ? "chevron.down" : "chevron.right"
            ) { [weak self] in self?.toggleCollapsed(id) })
        menu.addItem(.separator())
        let items = reorderItems
        let groupIDs = list.groupIDs
        addMoveItems(
            to: menu, can: { !TabReorder.stepGroup(id, by: $0, groups: groupIDs, items: items).isEmpty },
            move: { [weak self] step in self?.stepGroup(id, by: step) })
        menu.addItem(.separator())
        menu.addItem(
            MenuAction(String(localized: "Ungroup"), symbol: "rectangle.stack.badge.minus") { [weak self] in
                self?.ungroup(id)
            })
        menu.autoenablesItems = false
        return menu
    }
}
