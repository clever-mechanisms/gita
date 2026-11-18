import AppKit
import GitaCore

/// Tab colours, groups, and moving tabs and groups along the strip.
extension RepositoryTabsController {
    /// Hands the strip its chips and tabs in order; a group's chip goes in front of its first tab.
    func layoutStrip() {
        var items: [TabStripView.Item] = []
        var shown = Set<UUID>()
        for tab in tabs {
            let group = groupID(of: tab).flatMap(list.group)
            if let group, shown.insert(group.id).inserted {
                let chip = chips[group.id] ?? makeChip(group.id)
                chip.update(
                    group, count: list.members(of: group.id).count,
                    agents: group.collapsed ? groupAgents(group.id) : [])
                items.append(.chip(chip, group))
            }
            items.append(.tab(tab.button, group: group))
        }
        for id in chips.keys where !shown.contains(id) {
            chips[id]?.removeFromSuperview()
            chips[id] = nil
        }
        strip.setItems(items)
    }
    /// The agents in a group's checkouts (each session once, though two tabs show the same checkout), by tool.
    private func groupAgents(_ id: UUID) -> [AgentTally] {
        var seen = Set<String>()
        var sessions: [AgentSession] = []
        for tab in tabs where groupID(of: tab) == id {
            guard let root = tab.root else { continue }
            for session in WindowAgents.shared.sessions(checkout: root) where seen.insert(session.id).inserted {
                sessions.append(session)
            }
        }
        return AgentTally.byTool(sessions)
    }
    private func makeChip(_ id: UUID) -> TabGroupChipView {
        let chip = TabGroupChipView()
        chip.onToggle = { [weak self] in self?.toggleCollapsed(id) }
        chip.menuProvider = { [weak self] in self?.groupMenu(id) }
        chip.onTrack = { [weak self] event in self?.strip.trackDrag(.group(id), from: event) ?? false }
        chips[id] = chip
        return chip
    }
    func groupsChanged() {
        refreshTabs()
        if let tab = selectedTab { strip.scrollToVisible(tab.button.frame) }
    }
    func setColor(_ color: TabColor?, of tab: Tab) {
        tab.color = color
        refreshTabs()
    }
    func addToNewGroup(_ tab: Tab) {
        askGroupName(title: String(localized: "New Tab Group"), name: "", confirm: String(localized: "Create Group")) {
            [weak self, weak tab] name in
            guard let self, let tab, self.index(of: tab) != nil else { return }
            let group = self.list.addGroup(named: name)
            self.move(tab, into: group.id)
        }
    }
    /// A linked worktree opened while its repository (or another of its worktrees) has a tab joins that tab's group,
    /// or both start one named after the repository. Settings ▸ Appearance ▸ Tabs turns it off; once per tab.
    func groupWithRepository(_ tab: Tab) {
        guard !tab.wasGrouped, tab.author == nil, let main = tab.mainCheckout else { return }
        tab.wasGrouped = true
        guard environment.groupsWorktreeTabs(), groupID(of: tab) == nil,
            let partner = tabs.first(where: { other in
                other !== tab && other.author == nil
                    && [other.root, other.mainCheckout].contains { $0.map { sameRepository($0, main) } == true }
            })
        else { return }
        let group =
            groupID(of: partner)
            ?? {
                let name = main.pathExtension == "git" ? main.deletingPathExtension() : main
                let created = list.addGroup(named: name.lastPathComponent)
                list.move(partner.id, into: created.id)
                return created.id
            }()
        list.move(tab.id, into: group)
        groupsChanged()
    }
    func move(_ tab: Tab, into group: UUID) {
        list.move(tab.id, into: group)
        groupsChanged()
    }
    func removeFromGroup(_ tab: Tab) {
        list.removeFromGroup(tab.id)
        groupsChanged()
    }
    func ungroup(_ id: UUID) {
        list.ungroup(id)
        groupsChanged()
    }

    // MARK: Moving

    /// The strip's chips and shown tabs at their places, for `TabReorder`.
    var reorderItems: [TabReorder.Item<UUID>] {
        strip.layoutItems.compactMap { item, frame in
            switch item {
            case .chip(_, let group):
                return TabReorder.Item(.chip(group.id, collapsed: group.collapsed), minX: frame.minX, maxX: frame.maxX)
            case .tab(let view, let group):
                guard let index = tabs.firstIndex(where: { $0.button === view }) else { return nil }
                return TabReorder.Item(.tab(index, group: group?.id), minX: frame.minX, maxX: frame.maxX)
            }
        }
    }
    /// A drag moved its tab or group to `left`: reorder now so the other tabs make room.
    func dragMoved(_ subject: TabStripView.DragSubject, to left: CGFloat) {
        guard !isDetached else { return }
        let items = reorderItems
        switch subject {
        case .tab(let view):
            guard let index = tabs.firstIndex(where: { $0.button === view }) else { return }
            let drop = TabReorder.dropTab(index, at: Double(left), groups: list.groupIDs, items: items)
            reorder(drop.order, moving: tabs[index], into: drop.group)
        case .group(let id):
            reorder(TabReorder.dropGroup(id, at: Double(left), groups: list.groupIDs, items: items))
        }
    }
    /// Move Left / Move Right in a tab's menu.
    func step(_ tab: Tab, by step: Int) {
        guard let index = index(of: tab),
            let moved = TabReorder.stepTab(index, by: step, groups: list.groupIDs, items: reorderItems)
        else {
            NSSound.beep()
            return
        }
        reorder(moved.order, moving: tab, into: moved.group)
        strip.scrollToVisible(tab.button.frame)
    }
    /// Move Left / Move Right in a group's menu.
    func stepGroup(_ id: UUID, by step: Int) {
        let order = TabReorder.stepGroup(id, by: step, groups: list.groupIDs, items: reorderItems)
        guard !order.isEmpty else {
            NSSound.beep()
            return
        }
        reorder(order)
        if let chip = chips[id] { strip.scrollToVisible(chip.frame) }
    }
    private func reorder(_ order: [Int], moving tab: Tab? = nil, into group: UUID? = nil) {
        if list.reorder(order, moving: tab?.id, into: group) { refreshTabs() }
    }
    func toggleCollapsed(_ id: UUID) {
        guard let group = list.group(id) else { return }
        let collapsing = !group.collapsed
        if collapsing, let selected = selectedTab, groupID(of: selected) == id {
            // The tab on screen cannot hide: show the nearest tab outside the group first (after it, else before).
            guard let next = list.nearestOutside(id), canChangeRepository else {
                NSSound.beep()
                return
            }
            select(next)
            guard let shown = selectedTab, groupID(of: shown) != id else { return }
        }
        // Set, not toggled: leaving the group above may already have collapsed it.
        list.setCollapsed(collapsing, group: id)
        refreshTabs()
    }
    func renameGroup(_ id: UUID) {
        guard let group = list.group(id) else { return }
        askGroupName(
            title: String(localized: "Rename Tab Group"), name: group.name, confirm: String(localized: "Rename")
        ) { [weak self] name in
            guard let self else { return }
            self.list.rename(id, to: name)
            self.refreshTabs()
        }
    }
    func setGroupColor(_ color: TabColor, of id: UUID) {
        list.setColor(color, group: id)
        refreshTabs()
    }
    /// A name for a group (empty is allowed: the chip then shows only its colour).
    private func askGroupName(
        title: String, name: String, confirm: String, completion: @escaping @MainActor (String) -> Void
    ) {
        guard let window = view.window, window.attachedSheet == nil else {
            NSSound.beep()
            return
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: String(localized: "Cancel"))
        let field = NSTextField(string: name)
        field.placeholderString = String(localized: "Group name (optional)")
        field.setAccessibilityLabel(String(localized: "Group name"))
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        environment.presentAlert(alert, window) { response in
            guard response == .alertFirstButtonReturn else { return }
            completion(Self.groupName(field.stringValue))
        }
    }
    static func groupName(_ input: String) -> String {
        String(input.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
    }
}
