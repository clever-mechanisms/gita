import AppKit
import GitaCore
import Testing

@testable import GitaUI

@MainActor
@Suite("Tabs: controller groups, menus and moving")
struct TabsGroupTests {
    /// Three loaded tabs with alpha and beta in a group named "Pair".
    private func grouped() async throws -> (TabsHarness, UUID) {
        let harness = try TabsHarness()
        let tabs = try harness.openLoaded(["alpha", "beta", "gamma"])
        harness.recorder.typedName = "  Pair  "
        try TabsHarness.run("Add to New Group…", in: harness.controller.menu(for: tabs[0]))
        let group = try #require(harness.controller.groupID(of: tabs[0]))
        try TabsHarness.run("Pair", in: harness.controller.menu(for: tabs[1]))
        return (harness, group)
    }

    @Test func tabMenuBuildsGroups() async throws {
        let (harness, group) = try await grouped()
        let controller = harness.controller
        let tabs = controller.tabs
        #expect(controller.list.group(group)?.name == "Pair")
        #expect(controller.groupID(of: tabs[1]) == group)
        #expect(controller.chips[group] != nil)
        #expect(harness.recorder.alerts.first?.messageText == "New Tab Group")
        // A grouped tab can leave; there is no other group to join.
        let menu = controller.menu(for: tabs[0])
        #expect((try? TabsHarness.item("Add to Group", in: menu)) == nil)
        try TabsHarness.run("Remove from Group", in: menu)
        #expect(controller.groupID(of: tabs[0]) == nil)
        #expect(harness.names() == ["beta", "alpha", "gamma"])
        // A cancelled name creates nothing.
        harness.recorder.alertResponse = .alertSecondButtonReturn
        try TabsHarness.run("Add to New Group…", in: controller.menu(for: tabs[2]))
        #expect(controller.list.groups.count == 1)
        // Without a window there is no name to ask for.
        harness.window.contentViewController = nil
        harness.recorder.alertResponse = .alertFirstButtonReturn
        controller.addToNewGroup(tabs[2])
        #expect(harness.recorder.alerts.count == 2)
    }

    /// `tab` now shows a linked worktree of `main`.
    private static func showWorktree(_ tab: RepositoryTabsController.Tab, of main: URL) throws {
        let root = try #require(tab.root)
        tab.model.snapshot = RepositorySnapshot(
            root: root, branch: "feature", head: nil, changes: [], commits: [], references: [],
            worktrees: [
                GitWorktree(path: main.path, branch: "main", head: ""),
                GitWorktree(path: root.path, branch: "feature", head: ""),
            ],
            stashes: [], remoteURL: nil, gitDirectory: main.appendingPathComponent(".git"))
    }

    @Test func aWorktreeJoinsItsRepositorysTabInAGroupNamedAfterIt() async throws {
        let harness = try TabsHarness()
        let tabs = try harness.openLoaded(["alpha", "beta", "gamma"])
        let controller = harness.controller
        let main = try harness.url("alpha")
        try Self.showWorktree(tabs[2], of: main)
        controller.groupWithRepository(tabs[2])
        let group = try #require(controller.groupID(of: tabs[0]))
        #expect(controller.groupID(of: tabs[2]) == group)
        #expect(controller.list.group(group)?.name == "alpha")
        #expect(harness.names() == ["alpha", "gamma", "beta"])
        #expect(tabs[2].mainCheckout?.lastPathComponent == "alpha")
        // Once only: taken out, it stays out.
        controller.removeFromGroup(tabs[2])
        controller.groupWithRepository(tabs[2])
        #expect(controller.groupID(of: tabs[2]) == nil)
        // Another worktree of the same repository joins the existing group.
        try Self.showWorktree(tabs[1], of: main)
        controller.groupWithRepository(tabs[1])
        #expect(controller.groupID(of: tabs[1]) == group)
    }

    @Test func worktreeGroupingCanBeTurnedOff() async throws {
        let harness = try TabsHarness()
        harness.recorder.groupsWorktreeTabs = false
        let tabs = try harness.openLoaded(["alpha", "beta"])
        try Self.showWorktree(tabs[1], of: try harness.url("alpha"))
        harness.controller.groupWithRepository(tabs[1])
        #expect(harness.controller.list.groups.isEmpty)
        // A repository's own tab is not a worktree.
        #expect(tabs[0].mainCheckout == nil)
    }

    @Test func tabColoursAndClosingFromTheMenu() async throws {
        let harness = try TabsHarness()
        let tabs = try harness.openLoaded(["alpha", "beta"])
        let controller = harness.controller
        try TabsHarness.run("Purple", in: controller.menu(for: tabs[0]))
        #expect(tabs[0].color == .purple)
        #expect(try TabsHarness.item("Purple", in: controller.menu(for: tabs[0])).state == .on)
        #expect(controller.session.color(for: try #require(tabs[0].root)) == .purple)
        try TabsHarness.run("No Color", in: controller.menu(for: tabs[0]))
        #expect(tabs[0].color == nil)
        try TabsHarness.run("Close Tab", in: controller.menu(for: tabs[0]))
        #expect(harness.names() == ["beta"])
    }

    @Test func silencingATabsNotificationsFromTheMenu() async throws {
        let harness = try TabsHarness()
        let tabs = try harness.openLoaded(["alpha", "beta"])
        let controller = harness.controller
        let alpha = try #require(tabs[0].root)
        try TabsHarness.run("Silence Notifications", in: controller.menu(for: tabs[0]))
        #expect(harness.recorder.silenced == [alpha])
        #expect(tabs[0].button.shown?.silenced == true)
        #expect(tabs[1].button.shown?.silenced == false)
        #expect(tabs[0].button.shown?.toolTip.contains("Notifications silenced") == true)
        #expect(tabs[0].button.shown?.accessibilityLabel.hasSuffix("Notifications silenced") == true)
        #expect((try? TabsHarness.item("Silence Notifications", in: controller.menu(for: tabs[0]))) == nil)
        try TabsHarness.run("Allow Notifications", in: controller.menu(for: tabs[0]))
        #expect(harness.recorder.silenced.isEmpty)
        #expect(tabs[0].button.shown?.silenced == false)
        // Another window silencing the repository updates this one's tabs.
        harness.recorder.silenced = [alpha]
        NotificationCenter.default.post(name: SilencedRepositories.didChange, object: nil)
        #expect(tabs[0].button.shown?.silenced == true)
    }

    @Test func tabsMoveLeftAndRight() async throws {
        let harness = try TabsHarness()
        let tabs = try harness.openLoaded(["alpha", "beta", "gamma"])
        let controller = harness.controller
        let first = controller.menu(for: tabs[0])
        #expect(try !TabsHarness.item("Move Left", in: first).isEnabled)
        try TabsHarness.run("Move Right", in: first)
        #expect(harness.names() == ["beta", "alpha", "gamma"])
        try TabsHarness.run("Move Left", in: controller.menu(for: tabs[2]))
        #expect(harness.names() == ["beta", "gamma", "alpha"])
        controller.step(tabs[0], by: 1)
        #expect(harness.names() == ["beta", "gamma", "alpha"])
        // Dragging a tab far left puts it first.
        controller.dragMoved(.tab(tabs[0].button), to: 0)
        #expect(harness.names() == ["alpha", "beta", "gamma"])
        controller.dragMoved(.tab(NSView()), to: 0)
        controller.strip.onDrag?(.tab(tabs[2].button), 0)
        controller.strip.onDragEnd?()
        #expect(harness.names() == ["gamma", "alpha", "beta"])
    }

    @Test func groupMenuRenamesRecoloursAndMoves() async throws {
        let (harness, group) = try await grouped()
        let controller = harness.controller
        #expect(controller.groupMenu(UUID()) == nil)
        harness.recorder.typedName = "Renamed"
        try TabsHarness.run("Rename Group…", in: controller.groupMenu(group))
        #expect(controller.list.group(group)?.name == "Renamed")
        #expect(harness.recorder.alerts.last?.messageText == "Rename Tab Group")
        try TabsHarness.run("Red", in: controller.groupMenu(group))
        #expect(controller.list.group(group)?.color == .red)
        #expect((try? TabsHarness.item("No Color", in: controller.groupMenu(group))) == nil)
        let menu = controller.groupMenu(group)
        #expect(try !TabsHarness.item("Move Left", in: menu).isEnabled)
        try TabsHarness.run("Move Right", in: menu)
        #expect(harness.names() == ["gamma", "alpha", "beta"])
        try TabsHarness.run("Move Left", in: controller.groupMenu(group))
        #expect(harness.names() == ["alpha", "beta", "gamma"])
        controller.stepGroup(group, by: -1)
        controller.dragMoved(.group(group), to: 10_000)
        #expect(harness.names() == ["gamma", "alpha", "beta"])
        // A second group offers the first in each tab's menu.
        try TabsHarness.run("Add to New Group…", in: controller.menu(for: controller.tabs[0]))
        try TabsHarness.run("Renamed", in: controller.menu(for: controller.tabs[0]))
        #expect(controller.groupID(of: controller.tabs[0]) == group)
        try TabsHarness.run("Ungroup", in: controller.groupMenu(group))
        #expect(controller.list.groups.isEmpty)
        #expect(controller.chips.isEmpty)
    }

    @Test func collapsingShowsATabOutsideTheGroup() async throws {
        let (harness, group) = try await grouped()
        let controller = harness.controller
        controller.select(0)
        try TabsHarness.run("Collapse Group", in: controller.groupMenu(group))
        #expect(controller.list.group(group)?.collapsed == true)
        #expect(controller.selectedRepository?.lastPathComponent == "gamma")
        #expect(try TabsHarness.item("Expand Group", in: controller.groupMenu(group)).isEnabled)
        controller.refreshTabs()
        // Choosing a hidden tab opens its group.
        controller.selectTab(number: 1)
        #expect(controller.list.group(group)?.collapsed == false)
        // Leaving the group collapses it when the setting says so.
        harness.recorder.collapsesLeftGroups = true
        controller.select(2)
        #expect(controller.list.group(group)?.collapsed == true)
        controller.toggleCollapsed(group)
        #expect(controller.list.group(group)?.collapsed == false)
        controller.toggleCollapsed(UUID())
        controller.chips[group]?.onToggle?()
        #expect(controller.list.group(group)?.collapsed == true)
        #expect(controller.chips[group]?.menuProvider?() != nil)
        NotificationCenter.default.post(name: .gitaInterfaceFontChanged, object: nil)
    }

    @Test func aGroupHoldingEveryTabCannotCollapse() async throws {
        let (harness, group) = try await grouped()
        let controller = harness.controller
        try TabsHarness.run("Pair", in: controller.menu(for: controller.tabs[2]))
        controller.select(0)
        controller.toggleCollapsed(group)
        #expect(controller.list.group(group)?.collapsed == false)
        #expect(controller.selectedIndex == 0)
    }

    @Test func detachingKeepsOnlyTheChosenModel() async throws {
        let harness = try TabsHarness()
        let tabs = try harness.openLoaded(["alpha", "beta"])
        let controller = harness.controller
        let kept = tabs[0].model
        controller.detach(preserving: kept)
        controller.detach(preserving: kept)
        #expect(controller.isDetached)
        #expect(controller.isEmpty)
        #expect(kept.isActiveRepository)
        #expect(!tabs[1].model.isActiveRepository)
        #expect(!controller.canChangeRepository)
        controller.select(0)
        controller.refreshSharedPreferences()
        controller.dragMoved(.tab(tabs[0].button), to: 0)
        controller.modelChanged(.repository, in: tabs[0])
        controller.mergeDuplicate(tabs[0])
        #expect(controller.isEmpty)
    }
}
