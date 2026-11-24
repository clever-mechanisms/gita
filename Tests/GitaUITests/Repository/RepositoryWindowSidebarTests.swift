import AppKit
import GitaCore
import Testing

@testable import GitaUI

/// The repository window's sidebar, panes, pages and review sheets, on a real repository.
@MainActor
@Suite("Repository window · sidebar and panes", .serialized)
struct RepositoryWindowSidebarTests {
    private func row(_ fixture: RepositoryWindowFixture, _ match: (RepositorySidebarView.Row) -> Bool) throws -> Int {
        let index = fixture.controller.sidebarView.rows.firstIndex(where: match)
        return try #require(index)
    }

    private func nav(_ page: SidebarSelection) -> (RepositorySidebarView.Row) -> Bool {
        { if case .nav(let nav) = $0 { nav.target == .page(page) } else { false } }
    }

    private func nav(_ group: SidebarGroupID) -> (RepositorySidebarView.Row) -> Bool {
        { if case .nav(let nav) = $0 { nav.target == .group(group) } else { false } }
    }

    @Test func theSidebarListsTheRepositoryAndItsReferences() async throws {
        let fixture = try await RepositoryWindowFixture(prepare: RepositoryWindowFixture.mergedFeature)
        defer { fixture.close() }
        let sidebar = fixture.controller.sidebarView
        let names = sidebar.rows.compactMap { row -> String? in
            switch row {
            case .nav(let nav): nav.title
            case .reference(let reference): reference.reference.name
            case .stash(let stash, _): stash.subject
            case .repository(let repository, _): repository.name
            default: nil
            }
        }
        #expect(names.contains("Local Changes"))
        #expect(names.contains("All Commits"))
        #expect(names.contains("main"))
        #expect(names.contains("Tags"))
        #expect(names.contains(fixture.repository.url.lastPathComponent))
        // Every row draws.
        for index in sidebar.rows.indices {
            #expect(sidebar.tableView(sidebar.repositoryPane.list.table, viewFor: nil, row: index) != nil)
            _ = sidebar.tableView(sidebar.repositoryPane.list.table, heightOfRow: index)
            _ = sidebar.tableView(sidebar.repositoryPane.list.table, shouldSelectRow: index)
        }
        UITestSupport.render(sidebar)
    }

    @Test func emptyGroupsOpenOntoASayingLineAndRemotesShowTheirHost() async throws {
        let fixture = try await RepositoryWindowFixture()
        defer { fixture.close() }
        let sidebar = fixture.controller.sidebarView
        let empties = {
            sidebar.rows.compactMap { row -> String? in if case .empty(let text) = row { text } else { nil } }
        }
        for group in [SidebarGroupID.tags, .stashes, .remotes] {
            sidebar.activate(try row(fixture, nav(group)), fromKeyboard: false)
        }
        #expect(
            Set(empties()) == [
                String(localized: "No tags"), String(localized: "No stashes"), String(localized: "No remotes"),
            ])
        try fixture.repository.git("remote", "add", "origin", "git@github.com:owner/repo.git")
        try fixture.repository.git("update-ref", "refs/remotes/origin/main", "HEAD")
        try await fixture.refresh()
        try await fixture.wait("the remote") {
            sidebar.rows.contains { if case .remote(_, _, _, let brand) = $0 { brand == .github } else { false } }
        }
        #expect(!empties().contains(String(localized: "No remotes")))
        #expect(fixture.model.snapshot?.remoteURLs["origin"]?.contains("github.com") == true)
        #expect(fixture.model.snapshot?.githubRemotes.contains("origin") == true)
        UITestSupport.render(sidebar)

        var aliasInput = RepositorySidebarView.Input()
        aliasInput.currentRoot = fixture.repository.url
        aliasInput.remotes = ["sqligrp"]
        aliasInput.remoteURLs = ["sqligrp": "git@sqligrp:sqligrp/repo.git"]
        aliasInput.githubRemotes = ["sqligrp"]
        sidebar.update(aliasInput)
        #expect(
            sidebar.rows.contains {
                if case .remote(let name, _, _, let brand) = $0 { name == "sqligrp" && brand == .github } else { false }
            })
    }

    @Test func choosingSidebarRowsNavigates() async throws {
        let fixture = try await RepositoryWindowFixture(prepare: RepositoryWindowFixture.mergedFeature)
        defer { fixture.close() }
        let sidebar = fixture.controller.sidebarView
        let model = fixture.model
        sidebar.activate(try row(fixture, nav(SidebarSelection.changes)), fromKeyboard: false)
        #expect(model.section == .changes)
        sidebar.activate(try row(fixture, nav(SidebarSelection.history)), fromKeyboard: false)
        #expect(model.section == .history)

        // Groups open and close by click; arrowing onto one leaves it as it is.
        sidebar.activate(try row(fixture, nav(SidebarGroupID.tags)), fromKeyboard: false)
        let tag = try row(fixture) { if case .reference(let ref) = $0 { ref.reference.name == "v1.0" } else { false } }
        sidebar.activate(tag, fromKeyboard: false)
        try await fixture.wait("the tagged commit") { model.selectedCommit?.decorations.contains("tag: v1.0") == true }
        #expect(fixture.controller.sidebarSelection == .reference(fullName: "refs/tags/v1.0"))
        sidebar.activate(try row(fixture, nav(SidebarGroupID.tags)), fromKeyboard: true)

        sidebar.activate(try row(fixture, nav(SidebarGroupID.stashes)), fromKeyboard: false)
        let stash = try row(fixture) { if case .stash = $0 { true } else { false } }
        sidebar.activate(stash, fromKeyboard: false)
        try await fixture.wait("the stash") { model.selectedStash != nil }
        #expect(fixture.controller.sidebarSelectionID == .stash(ref: "stash@{0}"))
        #expect(!fixture.controller.detailBar.applyStash.isHidden)

        sidebar.activate(try row(fixture, nav(SidebarSelection.history)), fromKeyboard: false)
        try await fixture.wait("all commits") { model.selectedStash == nil }

        // Branches fold into folders (feature/login under "feature").
        let branches = try row(fixture, nav(SidebarGroupID.branches))
        if case .nav(let group) = sidebar.rows[branches], group.expansion != .expanded {
            sidebar.activate(branches, fromKeyboard: false)
        }
        let folder = try row(fixture) { if case .folder(let folder) = $0 { folder.name == "feature" } else { false } }
        sidebar.activate(folder, fromKeyboard: false)
        sidebar.activate(folder, fromKeyboard: false)

        sidebar.activate(try row(fixture, nav(SidebarSelection.pullRequests)), fromKeyboard: false)
        #expect(model.section == .pullRequests)
        #expect(!fixture.controller.pagePane.isHidden)
        #expect(fixture.controller.historyPane.isHidden)
        sidebar.activate(try row(fixture, nav(SidebarSelection.deployments)), fromKeyboard: false)
        #expect(fixture.controller.providerPage.section == .deployments)
        sidebar.activate(try row(fixture, nav(SidebarSelection.workflows)), fromKeyboard: false)
        #expect(fixture.controller.providerPage.section == .workflows)
    }

    @Test func groupsOpenAndCloseByKeyboardAndVoiceOver() async throws {
        let fixture = try await RepositoryWindowFixture(prepare: RepositoryWindowFixture.mergedFeature)
        defer { fixture.close() }
        let sidebar = fixture.controller.sidebarView
        let table = sidebar.repositoryPane.list.table
        let tagsRow = { try self.row(fixture, self.nav(SidebarGroupID.tags)) }
        let tagsOpen = {
            if case .nav(let nav) = sidebar.rows[try tagsRow()] { nav.expansion == .expanded } else { false }
        }
        // A click never selects a group; the arrow keys stop on it.
        sidebar.currentEventType = { .leftMouseDown }
        #expect(!sidebar.tableView(table, shouldSelectRow: try tagsRow()))
        sidebar.currentEventType = { .keyDown }
        #expect(sidebar.tableView(table, shouldSelectRow: try tagsRow()))
        table.selectRowIndexes(IndexSet(integer: try tagsRow()), byExtendingSelection: false)
        let wasOpen = try tagsOpen()

        let space = try #require(SharedEvents.key(" ", code: KeyPress.space))
        table.keyDown(with: space)
        #expect(try tagsOpen() == !wasOpen)
        #expect(table.selectedRow == (try tagsRow()))
        table.keyDown(with: try #require(SharedEvents.key("", code: KeyPress.rightArrow)))
        #expect(try tagsOpen())
        table.keyDown(with: try #require(SharedEvents.key("", code: KeyPress.rightArrow)))
        #expect(try tagsOpen())
        table.keyDown(with: try #require(SharedEvents.key("", code: KeyPress.leftArrow)))
        #expect(try !tagsOpen())

        // VoiceOver hears the state and presses the row to toggle it.
        let cell = try #require(sidebar.tableView(table, viewFor: nil, row: try tagsRow()) as? SidebarCell)
        #expect(!cell.isAccessibilityExpanded())
        #expect(cell.accessibilityPerformPress())
        #expect(try tagsOpen())
        let opened = try #require(sidebar.tableView(table, viewFor: nil, row: try tagsRow()) as? SidebarCell)
        #expect(opened.isAccessibilityExpanded())

        // Off a group the keys stay the table's.
        let history = try row(fixture, nav(SidebarSelection.history))
        table.selectRowIndexes(IndexSet(integer: history), byExtendingSelection: false)
        #expect(!sidebar.changeGroup(history, .open))
        #expect(!sidebar.changeGroup(-1, .toggle))
        table.keyDown(with: try #require(SharedEvents.key("", code: KeyPress.rightArrow)))
    }

    @Test func groupKeysKeepTheirStoredSpellings() {
        #expect(SidebarGroupID.branches.persistedKey == "branches")
        #expect(SidebarGroupID.worktrees.persistedKey == "worktrees")
        #expect(SidebarGroupID.remotes.persistedKey == "remotes")
        #expect(SidebarGroupID.tags.persistedKey == "tags")
        #expect(SidebarGroupID.stashes.persistedKey == "stashes")
        #expect(SidebarGroupID.remote("origin").persistedKey == "remote:origin")
        #expect(SidebarGroupID.folder(in: .branches, path: "feature").persistedKey == "folder:branches:feature")
        #expect(
            SidebarGroupID.folder(in: .remote("origin"), path: "build/x").persistedKey
                == "folder:remote:origin:build/x")
        #expect(SidebarSelection(page: .worktrees) == .agents)
        #expect(SidebarSelection(page: .history) == nil)
        #expect(SidebarSelection.history.section == nil)
        #expect(SidebarSelection.workflows.section == .workflows)
    }

    @Test func theSidebarFilterAndItsMenus() async throws {
        let fixture = try await RepositoryWindowFixture(prepare: RepositoryWindowFixture.mergedFeature)
        defer { fixture.close() }
        let sidebar = fixture.controller.sidebarView
        sidebar.repositoryPane.filter.stringValue = "login"
        sidebar.filterChanged()
        #expect(
            sidebar.rows.contains {
                if case .reference(let ref) = $0 { ref.reference.name == "feature/login" } else { false }
            })
        #expect(
            !sidebar.rows.contains { if case .reference(let ref) = $0 { ref.reference.name == "main" } else { false } })
        sidebar.repositoryPane.filter.stringValue = "nothing matches this"
        sidebar.filterChanged()
        #expect(sidebar.rows.contains { if case .empty = $0 { true } else { false } })
        sidebar.repositoryPane.filter.stringValue = ""
        sidebar.filterChanged()

        let main = try row(fixture) { if case .reference(let ref) = $0 { ref.reference.name == "main" } else { false } }
        let referenceMenu = try #require(sidebar.menu(main))
        #expect(!referenceMenu.items.isEmpty)
        // Other suites can leave their repositories in the shared workspace monitor: pick this fixture's row.
        let repository = try row(fixture) {
            if case .repository(let listed, _) = $0 { listed.isCurrent } else { false }
        }
        let repositoryMenu = try #require(sidebar.menu(repository))
        let remove = try #require(repositoryMenu.item(titled: "Remove from List"))
        #expect(!remove.isEnabled)
        let checkout = try row(fixture) {
            if case .checkout(let checkout, _, _) = $0 { checkout.path == fixture.repository.url.path } else { false }
        }
        let checkoutMenu = try #require(sidebar.menu(checkout))
        checkoutMenu.item(titled: "Open in Tab")?.perform()
        #expect(fixture.commands.calls.last == "openRepositoryTab \(fixture.repository.url.lastPathComponent)")
        #expect(checkoutMenu.item(titled: "Open Remote in Browser") != nil)
        #expect(sidebar.menu(try row(fixture, nav(SidebarGroupID.remotes)))?.item(titled: "Manage Remotes…") != nil)
        #expect(sidebar.menu(0) == nil)

        // The sort menu re-sorts every sidebar.
        let order = sidebar.repositoryOrderMenu()
        order.item(titled: "Sort by Status")?.perform()
        #expect(SidebarState.shared(fixture.defaults).repositoryOrder == .status)
        sidebar.repositoryOrderMenu().item(titled: "Sort by Name")?.perform()

        // A pinned branch moves to the top of Branches.
        fixture.model.toggleBranchFilter(
            .pin, try #require(fixture.model.snapshot?.references.first { $0.name == "main" }))
        try await fixture.wait("the pin") { fixture.model.branchFilters.pinned == ["refs/heads/main"] }
        fixture.controller.rebuildSidebar()
    }

    @Test func repositoriesStartOpenAndSingleClickOpensAnyCheckout() async throws {
        let fixture = try await RepositoryWindowFixture()
        defer { fixture.close() }
        let sidebar = fixture.controller.sidebarView
        let path = fixture.repository.url.path
        func repositoryRow() throws -> Int {
            try row(fixture) { if case .repository(let listed, _) = $0 { listed.root.path == path } else { false } }
        }
        func isExpanded() throws -> Bool {
            if case .repository(_, let expanded) = sidebar.rows[try repositoryRow()] { return expanded }
            return false
        }
        func checkoutRow() throws -> Int {
            try row(fixture) { if case .checkout(let checkout, _, _) = $0 { checkout.path == path } else { false } }
        }
        #expect(try isExpanded())
        var opened: [URL] = []
        sidebar.onOpenCheckout = { opened.append($0) }
        sidebar.click(try checkoutRow())
        #expect(opened.map(\.path) == [path], "single click opens the checkout immediately")
        sidebar.secondClick(try checkoutRow())
        #expect(opened.map(\.path) == [path, path], "double click matches single click")
        sidebar.activate(try checkoutRow(), fromKeyboard: true)
        #expect(opened.count == 2, "arrowing onto a checkout never opens it")
        sidebar.activate(try checkoutRow(), fromKeyboard: false)
        #expect(opened.count == 3, "Return opens the selected checkout")
        // Single-checkout repository row: opens on click and Return, never on arrow-key selection.
        sidebar.click(try repositoryRow())
        #expect(try isExpanded())
        #expect(opened.count == 4)
        sidebar.secondClick(try repositoryRow())
        #expect(opened.count == 5)
        sidebar.activate(try repositoryRow(), fromKeyboard: true)
        #expect(opened.count == 5)
        // Closed, clicking the repository row opens it and expands the row.
        SidebarState.shared(fixture.defaults).repositoryExpansion[path] = false
        sidebar.repositoriesPane.rebuild()
        #expect(try !isExpanded())
        sidebar.click(try repositoryRow())
        #expect(try isExpanded())
        #expect(opened.count == 6)
        let cell = try #require(
            sidebar.tableView(sidebar.repositoryPane.list.table, viewFor: nil, row: try checkoutRow()) as? SidebarCell)
        #expect(cell.accessibilityLabel()?.contains(String(localized: "Main checkout")) == true)
    }

    @Test func aRepositoryWithSeveralCheckoutsOpensPrimaryAndExpandsOnClick() async throws {
        let fixture = try await RepositoryWindowFixture { repository in
            try RepositoryWindowFixture.threeCommits(repository)
            let tree = repository.url.deletingLastPathComponent()
                .appendingPathComponent(repository.url.lastPathComponent + "-tree")
            try repository.git("worktree", "add", "-q", "-b", "side", tree.path)
        }
        defer { fixture.close() }
        let sidebar = fixture.controller.sidebarView
        let path = fixture.repository.url.path
        let tree = try #require(fixture.model.snapshot?.worktrees.dropFirst().first)
        defer { try? FileManager.default.removeItem(atPath: tree.path) }
        func repositoryRow() throws -> Int {
            try row(fixture) { if case .repository(let listed, _) = $0 { listed.root.path == path } else { false } }
        }
        func localRepoRow() throws -> Int {
            try #require(
                sidebar.repositoriesPane.rows.firstIndex {
                    if case .repository(let listed, _) = $0 { listed.root.path == path } else { false }
                })
        }
        func isExpanded() throws -> Bool {
            if case .repository(_, let expanded) = sidebar.rows[try repositoryRow()] { return expanded }
            return false
        }
        var opened: [URL] = []
        sidebar.onOpenCheckout = { opened.append($0) }
        #expect(try isExpanded())
        // Chevron toggles expansion only without opening.
        sidebar.repositoriesPane.list.performChevron(try localRepoRow())
        #expect(try !isExpanded())
        #expect(opened.isEmpty)
        // Arrow-key landing neither toggles nor opens.
        sidebar.activate(try repositoryRow(), fromKeyboard: true)
        #expect(try !isExpanded())
        #expect(opened.isEmpty)
        // Clicking the collapsed multi-checkout repository expands it and opens its main/MRU checkout.
        sidebar.click(try repositoryRow())
        #expect(try isExpanded())
        #expect(opened.map(\.path) == [path])
        // Clicking again while expanded opens the primary checkout without collapsing.
        sidebar.secondClick(try repositoryRow())
        #expect(try isExpanded())
        #expect(opened.map(\.path) == [path, path])
    }

    @Test func aCheckoutRowOfThisRepositoryShowsHistory() async throws {
        let fixture = try await RepositoryWindowFixture()
        defer { fixture.close() }
        fixture.model.section = .pullRequests
        fixture.controller.openRepository(fixture.repository.url)
        #expect(fixture.model.section == .history)
        fixture.controller.openRepository(URL(fileURLWithPath: "/tmp/another"))
        #expect(fixture.commands.calls == ["openRepositoryTab another"])
    }

    @Test func linkedWorktreesAreListedAndRemovable() async throws {
        let fixture = try await RepositoryWindowFixture { repository in
            try RepositoryWindowFixture.threeCommits(repository)
            let tree = repository.url.deletingLastPathComponent()
                .appendingPathComponent(repository.url.lastPathComponent + "-tree")
            try repository.git("worktree", "add", "-q", "-b", "side", tree.path)
        }
        defer { fixture.close() }
        let controller = fixture.controller
        let tree = try #require(fixture.model.snapshot?.worktrees.dropFirst().first)
        defer { try? FileManager.default.removeItem(atPath: tree.path) }
        #expect(
            controller.sidebarView.rows.contains {
                if case .nav(let nav) = $0 { nav.target == .group(.worktrees) } else { false }
            }
        )
        // Other suites can leave their repositories, all open, in the shared workspace monitor: count this one's.
        let paths = [fixture.repository.url.path, tree.path]
        let checkouts = controller.sidebarView.rows.filter {
            if case .checkout(let checkout, _, _) = $0 { paths.contains(checkout.path) } else { false }
        }
        #expect(checkouts.count == 2)
        let menu = try #require(controller.checkoutMenu(path: tree.path, isMain: false))
        let remove = try #require(menu.item(titled: "Remove Worktree…"))
        #expect(remove.isEnabled)
        remove.perform()
        let worktree = try #require(
            controller.sidebarView.rows.firstIndex {
                if case .nav(let nav) = $0 { nav.target == .group(.worktrees) } else { false }
            })
        _ = controller.sidebarView.menu(worktree)
        controller.agentsPaneShown = true
        controller.applyAgentsPaneVisibility()
        #expect(controller.agentsPane.rows.contains { $0.checkoutPath == tree.path })
    }

    @Test func thePanesFollowTheirToggles() async throws {
        let fixture = try await RepositoryWindowFixture()
        defer { fixture.close() }
        let controller = fixture.controller
        controller.viewDidLayout()
        #expect(controller.panes.positioned)
        #expect(!controller.isAgentsPaneShown)
        controller.toggleAgentsPane()
        #expect(controller.isAgentsPaneShown)
        #expect(Preference.agentsPaneShown.bool(fixture.defaults))
        controller.showAgentsPane(expanding: nil)
        controller.toggleAgentsPane()
        #expect(!controller.isAgentsPaneShown)
        controller.showAgentsPane()
        #expect(controller.isAgentsPaneShown)

        controller.toggleSidebar()
        #expect(controller.sidebarView.isHidden)
        controller.toggleSidebar()
        #expect(!controller.sidebarView.isHidden)

        let geometry = try #require(controller.paneGeometry)
        var moved = geometry
        moved.bottomHeight += 40
        moved.sidebarHidden = true
        controller.adopt(moved)
        #expect(controller.sidebarView.isHidden)
        #expect(controller.panes.bottomHeight == geometry.bottomHeight + 40)
        controller.adopt(geometry)
        controller.settleLayout()
        controller.positionHistorySplit()
        controller.focusSearch()
        controller.checkoutLoadingChanged()
        controller.codeFontChanged()
        controller.agentsChanged()
        fixture.model.section = .agents
        #expect(controller.isAgentsPaneShown)
        try await fixture.wait("the page again") { fixture.model.section == .history }
    }

    @Test func reviewSheetsOpenOneAtATime() async throws {
        let fixture = try await RepositoryWindowFixture()
        defer { fixture.close() }
        let controller = fixture.controller
        let commit = try #require(controller.historyCommits.last)
        controller.reviewReset(commit)
        #expect(controller.hasReviewSheet)
        // The window has its sheet: no second one.
        controller.manageRemotes()
        controller.requestApplicationTermination { _ in }
        #expect(controller.closeReviewSheet())
        controller.dismissReviewsForTermination()
        #expect(!controller.hasReviewSheet)

        try await fixture.wait("no sheet") { fixture.window.attachedSheet == nil }
        controller.manageRemotes()
        #expect(controller.hasReviewSheet)
        controller.dismissReviewsForTermination()
        try await fixture.wait("no sheet") { fixture.window.attachedSheet == nil }
        controller.reviewInteractiveRebase(after: commit)
        #expect(controller.hasReviewSheet)
        controller.dismissReviewsForTermination()
        try await fixture.wait("no sheet") { fixture.window.attachedSheet == nil }
        controller.reviewReference(.createTag(commit))
        #expect(controller.hasReviewSheet)
        controller.detach()
        controller.dismissReviewsForTermination()
    }
}
