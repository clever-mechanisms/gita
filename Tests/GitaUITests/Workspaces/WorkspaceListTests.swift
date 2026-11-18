import AppKit
import Foundation
import Testing

@testable import GitaUI

/// A workspace added to `list` under `name`, which must be usable.
func addedWorkspace(_ name: String, to list: inout WorkspaceList) throws -> Workspace {
    let added = list.add(named: name)
    return try #require(added)
}

@Suite("Workspaces: the list")
struct WorkspaceListTests {
    /// A fresh defaults domain, removed after `body`.
    private static func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "GitaUITests-Workspaces-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test func itStartsWithOneUnnamedWorkspaceOnTheKeysUsedBefore() {
        let list = WorkspaceList()
        #expect(list.workspaces.count == 1)
        #expect(list.active.id == Workspace.firstID)
        #expect(list.active.name == nil)
        #expect(list.active.title == String(localized: "Default"))
        #expect(list.active.sessionKey == "repositoryTabSession")
        #expect(list.active.recentKey == Preference.recentRepositories.rawValue)
        #expect(!list.canRemove)
        #expect(list.neighbor(of: Workspace.firstID) == nil)
    }

    @Test func addedWorkspacesHaveTheirOwnKeysAndCleanNames() throws {
        var list = WorkspaceList()
        #expect(list.suggestedName == String(localized: "Workspace \(2)"))
        let client = try addedWorkspace("  Client  ", to: &list)
        #expect(client.name == "Client")
        #expect(client.sessionKey == "repositoryTabSession.\(client.id)")
        #expect(client.recentKey == "recentRepositories.\(client.id)")
        let blank = list.add(named: "   ")
        #expect(blank == nil)
        let long = try addedWorkspace(String(repeating: "x", count: 90), to: &list)
        #expect(long.name?.count == WorkspaceList.nameLimit)
        // A name cut at a space does not end with it.
        let cut = try addedWorkspace(String(repeating: "x", count: WorkspaceList.nameLimit - 1) + " tail", to: &list)
        #expect(cut.name?.count == WorkspaceList.nameLimit - 1)
        #expect(list.workspaces.count == 4)
        // Adding does not change which workspace is in front.
        #expect(list.active.id == Workspace.firstID)
        #expect(list.canRemove)
    }

    @Test func theSuggestedNameSkipsNamesInUse() throws {
        var list = WorkspaceList()
        _ = try addedWorkspace(String(localized: "Workspace \(3)"), to: &list)
        #expect(list.suggestedName == String(localized: "Workspace \(4)"))
    }

    @Test func renamingKeepsTheWorkspaceAndRefusesAnEmptyName() throws {
        var list = WorkspaceList()
        let renamed = list.rename(Workspace.firstID, to: " Work ")
        #expect(renamed?.id == Workspace.firstID)
        #expect(list.active.title == "Work")
        let empty = list.rename(Workspace.firstID, to: "")
        let unknown = list.rename("unknown", to: "Other")
        #expect(empty == nil)
        #expect(unknown == nil)
        #expect(list.active.title == "Work")
    }

    @Test func removingMovesTheActiveWorkspaceToItsNeighbourAndKeepsTheLast() throws {
        var list = WorkspaceList()
        let second = try addedWorkspace("Second", to: &list)
        let third = try addedWorkspace("Third", to: &list)
        list.activate("unknown")
        #expect(list.active.id == Workspace.firstID)
        list.activate(third.id)
        #expect(list.neighbor(of: third.id) == second)
        #expect(list.neighbor(of: Workspace.firstID) == second)
        let removals = [third.id, "unknown", Workspace.firstID, second.id].map { list.remove($0) }
        #expect(removals == [true, false, true, false])
        #expect(list.active == second)
        #expect(list.workspaces == [second])
    }

    @Test func theListIsSavedAndRestored() throws {
        try Self.withDefaults { defaults in
            #expect(WorkspaceList.restore(from: defaults) == WorkspaceList())
            var list = WorkspaceList()
            let client = try addedWorkspace("Client", to: &list)
            list.activate(client.id)
            list.save(to: defaults)
            #expect(WorkspaceList.restore(from: defaults) == list)
        }
    }

    @Test func aDamagedListIsRepairedOrStartsAgain() throws {
        try Self.withDefaults { defaults in
            defaults.set(Data("nonsense".utf8), forKey: WorkspaceList.defaultsKey)
            #expect(WorkspaceList.restore(from: defaults) == WorkspaceList())
            let empty = #"{"activeID":"a","workspaces":[]}"#
            defaults.set(Data(empty.utf8), forKey: WorkspaceList.defaultsKey)
            #expect(WorkspaceList.restore(from: defaults) == WorkspaceList())
            let repeated = #"{"activeID":"gone","workspaces":[{"id":"a","name":"A"},{"id":"a","name":"B"},{"id":""}]}"#
            defaults.set(Data(repeated.utf8), forKey: WorkspaceList.defaultsKey)
            let restored = WorkspaceList.restore(from: defaults)
            #expect(restored.workspaces.map(\.title) == ["A"])
            #expect(restored.active.id == "a")
        }
    }

    @Test func aWorkspaceReadsAndForgetsItsOwnSettings() throws {
        try Self.withDefaults { defaults in
            var list = WorkspaceList()
            let client = try addedWorkspace("Client", to: &list)
            defaults.set(["/r/first"], forKey: list.active.recentKey)
            defaults.set(["/r/client"], forKey: client.recentKey)
            RepositoryTabSession(repositories: [URL(fileURLWithPath: "/r/client")])
                .save(to: defaults, key: client.sessionKey)
            #expect(client.recent(in: defaults) == ["/r/client"])
            #expect(list.active.recent(in: defaults) == ["/r/first"])
            #expect(RepositoryTabSession.restore(from: defaults) == nil)
            let saved = RepositoryTabSession.restore(from: defaults, key: client.sessionKey) { _ in true }
            #expect(saved?.repositories.map(\.path) == ["/r/client"])
            client.forget(in: defaults)
            #expect(client.recent(in: defaults).isEmpty)
            #expect(defaults.object(forKey: client.sessionKey) == nil)
            #expect(list.active.recent(in: defaults) == ["/r/first"])
        }
    }
}

@Suite("Workspaces: the menu") @MainActor
struct WorkspaceMenuTests {
    private final class Calls {
        var opened: [String] = []
        var commands: [String] = []
    }

    private func actions(_ calls: Calls) -> WorkspaceMenu.Actions {
        WorkspaceMenu.Actions(
            open: { calls.opened.append($0) }, new: { calls.commands.append("new") },
            rename: { calls.commands.append("rename") }, delete: { calls.commands.append("delete") })
    }

    private func press(_ item: NSMenuItem) {
        guard let action = item.action else { return }
        _ = item.target?.perform(action)
    }

    @Test func itListsTheWorkspacesWithTheShownOneChecked() throws {
        var list = WorkspaceList()
        let client = try addedWorkspace("Client", to: &list)
        let calls = Calls()
        let content = WorkspaceMenu.Content(
            list: list, shown: Workspace.firstID, windowed: [Workspace.firstID, client.id], canChange: true)
        let items = WorkspaceMenu.items(content, actions: actions(calls))
        #expect(items.map(\.title).prefix(2) == [String(localized: "Default"), "Client"])
        #expect(items[0].state == .on)
        #expect(items[1].state == .off)
        // Only a workspace in another window is marked as one.
        #expect(items[0].image == nil)
        #expect(items[1].image != nil)
        #expect(items[2].isSeparatorItem)
        #expect(items.dropFirst(3).allSatisfy { $0.isEnabled })
        items.filter { !$0.isSeparatorItem }.forEach(press)
        #expect(calls.opened == [Workspace.firstID, client.id])
        #expect(calls.commands == ["new", "rename", "delete"])
    }

    @Test func theOnlyWorkspaceCannotBeDeletedAndABusyWindowChangesNothing() throws {
        var list = WorkspaceList()
        let alone = WorkspaceMenu.Content(list: list, shown: Workspace.firstID, windowed: [], canChange: true)
        #expect(!alone.canDelete)
        #expect(WorkspaceMenu.items(alone, actions: actions(Calls())).last?.isEnabled == false)

        let client = try addedWorkspace("Client", to: &list)
        let busy = WorkspaceMenu.Content(
            list: list, shown: Workspace.firstID, windowed: [Workspace.firstID], canChange: false)
        let items = WorkspaceMenu.items(busy, actions: actions(Calls()))
        // The shown workspace can still be chosen (its window comes forward); the other cannot take its place now.
        #expect(items[0].isEnabled)
        #expect(!items[1].isEnabled)
        #expect(items.dropFirst(3).allSatisfy { !$0.isEnabled })
        #expect(busy.rows.map(\.id) == [Workspace.firstID, client.id])
    }

    @Test func aMenuIsFilledWhenMadeAndAgainWhenItOpens() {
        let menu = WorkspaceMenu()
        var titles = ["One"]
        menu.items = { titles.map { NSMenuItem(title: $0, action: nil, keyEquivalent: "") } }
        #expect(menu.menu().items.map(\.title) == ["One"])
        let submenu = menu.submenu(title: "Workspace")
        #expect(submenu.title == "Workspace")
        #expect(!submenu.autoenablesItems)
        titles = ["One", "Two"]
        submenu.delegate?.menuNeedsUpdate?(submenu)
        #expect(submenu.items.map(\.title) == ["One", "Two"])
    }
}
