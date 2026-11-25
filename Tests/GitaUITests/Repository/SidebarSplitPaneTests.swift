import AppKit
import GitaCore
import Testing

@testable import GitaUI

@MainActor
@Suite("Repository sidebar · split panes, scoped filter, recents and badges", .serialized)
struct SidebarSplitPaneTests {
    private func makeDefaults() throws -> (defaults: UserDefaults, suite: String) {
        let suite = "GitaUITests.sidebarSplit.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (defaults, suite)
    }

    private func branch(_ name: String, current: Bool = false) -> GitReference {
        GitReference(name: name, fullName: "refs/heads/\(name)", commit: "abc123", kind: .branch, isCurrent: current)
    }

    @Test func splitLayoutClampsDrawerToFortyPercentAndCollapsedHeight() {
        #expect(SidebarSplitLayout.maxHeight(totalHeight: 600, dividerThickness: 1) == 239)
        #expect(
            SidebarSplitLayout.clampedHeight(
                desired: 400, totalHeight: 600, dividerThickness: 1, collapsed: false) == 239)
        #expect(
            SidebarSplitLayout.clampedHeight(
                desired: 120, totalHeight: 600, dividerThickness: 1, collapsed: false) == 120)
        #expect(
            SidebarSplitLayout.clampedHeight(
                desired: 20, totalHeight: 600, dividerThickness: 1, collapsed: false) == 74)
        #expect(
            SidebarSplitLayout.clampedHeight(
                desired: 200, totalHeight: 600, dividerThickness: 1, collapsed: true) == 26)
        #expect(
            SidebarSplitLayout.clampedHeight(
                desired: 0, totalHeight: 600, dividerThickness: 1, collapsed: false) == 167)
        #expect(
            SidebarSplitLayout.clampedHeight(
                desired: 100, totalHeight: 0, dividerThickness: 1, collapsed: false) == 100)

        // Divider coordinates and bounds for top vs bottom placement.
        #expect(
            SidebarSplitLayout.dividerPosition(
                desired: 0, totalHeight: 600, dividerThickness: 1, collapsed: false, position: .top) == 167)
        #expect(
            SidebarSplitLayout.dividerPosition(
                desired: 0, totalHeight: 600, dividerThickness: 1, collapsed: false, position: .bottom) == 432)
        #expect(
            SidebarSplitLayout.dividerPosition(
                desired: 200, totalHeight: 600, dividerThickness: 1, collapsed: true, position: .bottom) == 573)
        let topBounds = SidebarSplitLayout.dividerBounds(
            totalHeight: 600, dividerThickness: 1, collapsed: false, position: .top)
        #expect(topBounds.min == 74 && topBounds.max == 239)
        let bottomBounds = SidebarSplitLayout.dividerBounds(
            totalHeight: 600, dividerThickness: 1, collapsed: false, position: .bottom)
        #expect(bottomBounds.min == 360 && bottomBounds.max == 525)
        let bottomCollapsed = SidebarSplitLayout.dividerBounds(
            totalHeight: 600, dividerThickness: 1, collapsed: true, position: .bottom)
        #expect(bottomCollapsed.min == 573 && bottomCollapsed.max == 573)
    }

    @Test func splitSidebarHostsPinnedCollapsibleDrawerAndScopedFilter() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = SidebarState.shared(defaults)
        let sidebar = RepositorySidebarView(state: state)
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        let hostController = NSViewController()
        hostController.view = sidebar
        let host = UITestSupport.host(hostController, size: NSSize(width: 240, height: 600))
        defer { host.close() }

        let alpha = URL(fileURLWithPath: "/tmp/alpha", isDirectory: true)
        let beta = URL(fileURLWithPath: "/tmp/beta", isDirectory: true)
        var input = RepositorySidebarView.Input()
        input.currentRoot = alpha
        input.currentName = "alpha"
        input.references = [branch("main", current: true), branch("feature/alpha")]
        input.recentBranches = ["feature/alpha", "main"]
        input.repositories = [
            RepositorySidebarView.Repository(
                root: alpha, name: "alpha", badge: "", badgeIsChange: false, isCurrent: true,
                checkouts: [
                    RepositorySidebarView.Checkout(
                        path: alpha.path, branch: "main", sessions: [], meta: "", isMain: true)
                ]),
            RepositorySidebarView.Repository(
                root: beta, name: "beta", badge: "↓2", badgeIsChange: false, isCurrent: false,
                checkouts: [
                    RepositorySidebarView.Checkout(
                        path: beta.path, branch: "main", sessions: [], meta: "↓2", isMain: true, behind: 2)
                ], behind: 2),
        ]
        sidebar.update(input)
        sidebar.layoutSubtreeIfNeeded()

        #expect(sidebar.split.arrangedSubviews.count == 2)
        #expect(sidebar.split.arrangedSubviews.first === sidebar.repositoryPane)
        #expect(sidebar.split.arrangedSubviews.last === sidebar.repositoriesPane)
        #expect(sidebar.repositoriesPane.frame.height <= 240)

        // Switching Repositories position via the header menu moves the drawer live and keeps clamping & collapse.
        let menu = sidebar.repositoryOrderMenu()
        #expect(menu.item(titled: String(localized: "Show at Bottom"))?.state == .on)
        #expect(menu.item(titled: String(localized: "Show at Top"))?.state == .off)
        menu.item(titled: String(localized: "Show at Top"))?.perform()
        sidebar.layoutSubtreeIfNeeded()
        #expect(state.repositoriesPosition == .top)
        #expect(sidebar.split.arrangedSubviews.first === sidebar.repositoriesPane)
        #expect(sidebar.split.arrangedSubviews.last === sidebar.repositoryPane)
        #expect(sidebar.repositoriesPane.frame.height <= 240)
        #expect(
            sidebar.splitView(sidebar.split, constrainMinCoordinate: 0, ofSubviewAt: 0)
                == SidebarSplitLayout.expandedMinimum)
        #expect(
            sidebar.splitView(sidebar.split, constrainMaxCoordinate: 600, ofSubviewAt: 0)
                == SidebarSplitLayout.maxHeight(totalHeight: 600, dividerThickness: sidebar.split.dividerThickness))

        sidebar.repositoryOrderMenu().item(titled: String(localized: "Show at Bottom"))?.perform()
        sidebar.layoutSubtreeIfNeeded()
        #expect(state.repositoriesPosition == .bottom)
        #expect(sidebar.split.arrangedSubviews.first === sidebar.repositoryPane)
        #expect(sidebar.split.arrangedSubviews.last === sidebar.repositoriesPane)
        #expect(sidebar.repositoriesPane.frame.height <= 240)

        // Lower filter scopes strictly to current repository refs and updates VoiceOver label.
        #expect(
            sidebar.repositoryPane.filter.placeholderString == String(localized: "Filter branches, tags, stashes…"))
        #expect(
            sidebar.repositoryPane.filter.accessibilityLabel() == String(localized: "Filter branches, tags, stashes"))
        func hasRepo(_ name: String) -> Bool {
            sidebar.repositoriesPane.rows.contains {
                if case .repository(let repo, _) = $0 { repo.name == name } else { false }
            }
        }
        sidebar.repositoryPane.filter.stringValue = "beta"
        sidebar.filterChanged()
        #expect(hasRepo("beta"))
        #expect(sidebar.repositoryPane.rows.contains { if case .empty = $0 { true } else { false } })
        sidebar.repositoryPane.filter.stringValue = ""
        sidebar.filterChanged()

        // Cmd+F inside Repositories pane reveals its local filter; Esc hides it.
        sidebar.repositoriesPane.showFilter()
        #expect(sidebar.repositoriesPane.isFilterVisible)
        sidebar.repositoriesPane.filter.stringValue = "beta"
        sidebar.repositoriesPane.filterChanged()
        #expect(!hasRepo("alpha"))
        #expect(hasRepo("beta"))
        sidebar.repositoriesPane.hideFilter()
        #expect(!sidebar.repositoriesPane.isFilterVisible)
        #expect(hasRepo("alpha"))

        // Collapsing Repositories drawer shrinks height to collapsedHeight and persists.
        sidebar.repositoriesPane.toggleCollapsed()
        sidebar.layoutSubtreeIfNeeded()
        #expect(state.repositoriesCollapsed)
        #expect(sidebar.repositoriesPane.isCollapsed)
        #expect(sidebar.repositoriesPane.frame.height == SidebarSplitLayout.collapsedHeight)
        sidebar.repositoriesPane.toggleCollapsed()
        sidebar.layoutSubtreeIfNeeded()
        #expect(!state.repositoriesCollapsed)
        #expect(sidebar.repositoriesPane.frame.height >= SidebarSplitLayout.expandedMinimum)

        // Empty currentRoot hides repositoryPane.
        input.currentRoot = nil
        sidebar.update(input)
        #expect(sidebar.repositoryPane.isHidden)
    }

    @Test func recentBranchesSectionShowsUpToFiveAndHidesWhileFiltering() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = SidebarState.shared(defaults)
        let names = ["b1", "b2", "b3", "b4", "b5", "b6"]
        var input = RepositorySidebarView.Input()
        input.currentRoot = URL(fileURLWithPath: "/tmp/repo", isDirectory: true)
        input.currentName = "repo"
        input.references = names.map { branch($0, current: $0 == "b1") }
        input.recentBranches = names + ["deleted-branch"]
        let builder = SidebarRowBuilder(
            input: input, query: "", repositoryExpansion: [:], groupExpansion: state.groupExpansion,
            order: .name, key: { WindowAgents.key($0) })
        let rows = builder.currentRepositoryRows()
        let subheaderIndex = try #require(rows.firstIndex { if case .subheader = $0 { true } else { false } })
        let recentNames = rows[(subheaderIndex + 1)...(subheaderIndex + 5)].compactMap { row -> String? in
            if case .reference(let ref) = row { return ref.reference.name }
            return nil
        }
        #expect(recentNames == ["b1", "b2", "b3", "b4", "b5"])

        let filtered = SidebarRowBuilder(
            input: input, query: "b6", repositoryExpansion: [:], groupExpansion: state.groupExpansion,
            order: .name, key: { WindowAgents.key($0) }
        ).currentRepositoryRows()
        #expect(!filtered.contains { if case .subheader = $0 { true } else { false } })
    }

    @Test func remoteBadgesAndMRUCheckoutSelectionWorkCorrectly() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = SidebarState.shared(defaults)
        let root = URL(fileURLWithPath: "/tmp/repo", isDirectory: true)
        let linked = URL(fileURLWithPath: "/tmp/repo-wt", isDirectory: true)
        state.recordCheckout(linked, for: root)
        let rootKey = RecentRepositories.canonical(root.path)
        #expect(state.mruCheckouts[rootKey] == RecentRepositories.canonical(linked.path))

        let movedCheckout = RepositorySidebarView.Checkout(
            path: linked.path, branch: "feature/x", sessions: [], meta: "⇣", isMain: false, behind: 0,
            remoteMoved: true)
        let mainCheckout = RepositorySidebarView.Checkout(
            path: root.path, branch: "main", sessions: [], meta: "↓3", isMain: true, behind: 3, remoteMoved: false)
        let badge = SidebarRepositoryList.badge(ahead: 1, behind: 3, changed: 0, remoteMoved: false)
        let repo = RepositorySidebarView.Repository(
            root: root, name: "repo", badge: badge, badgeIsChange: false, isCurrent: false,
            checkouts: [mainCheckout, movedCheckout], behind: 3, remoteMoved: false,
            mruCheckoutPath: state.mruCheckouts[rootKey])
        #expect(repo.primaryCheckoutURL.standardizedFileURL == linked.standardizedFileURL)
        #expect(repo.badge == "↓3 ↑1")
        #expect(SidebarRepositoryList.badge(ahead: 0, behind: 0, changed: 0, remoteMoved: true) == "⇣")

        let cell = SidebarCell()
        cell.configure(.checkout(movedCheckout, repository: root, selected: false))
        #expect(cell.accessibilityLabel()?.contains(String(localized: "Remote has un-fetched commits")) == true)
        #expect(cell.toolTip?.contains(String(localized: "Remote has un-fetched commits")) == true)

        state.forgetRepositories([root.path])
        #expect(state.mruCheckouts[rootKey] == nil)
    }

    @Test func recentBranchesReloadsAfterSwitchingToSecondBranchAtSameSHA() async throws {
        UITestSupport.bootstrap()
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = try TemporaryRepository()
        try repository.commit("README.md", "base\n", message: "Initial")
        try repository.git("checkout", "-q", "-b", "other")
        try repository.git("checkout", "-q", "main")
        try repository.git("branch", "same-sha")

        let service = GitService(root: repository.url)
        let pane = SidebarRepositoryPane(state: SidebarState.shared(defaults))

        func firstRecentBranch() -> String? {
            guard
                let headerIndex = pane.rows.firstIndex(where: {
                    if case .subheader(let title, _) = $0 { title == String(localized: "Recent") } else { false }
                }),
                pane.rows.indices.contains(headerIndex + 1),
                case .reference(let row) = pane.rows[headerIndex + 1]
            else { return nil }
            return row.reference.name
        }

        let snap1 = try await service.snapshot(limit: 10)
        var input1 = RepositorySidebarView.Input()
        input1.currentRoot = repository.url
        input1.currentName = repository.url.lastPathComponent
        input1.references = snap1.references
        pane.update(input1)
        pane.loadRecentBranchesIfNeeded(for: snap1, service: service)
        #expect(await eventually { firstRecentBranch() == "main" })

        try repository.git("checkout", "-q", "same-sha")
        let snap2 = try await service.snapshot(limit: 10)
        #expect(snap2.branch == "same-sha")
        #expect(snap2.head == snap1.head)

        var input2 = input1
        input2.references = snap2.references
        pane.update(input2)
        pane.loadRecentBranchesIfNeeded(for: snap2, service: service)
        #expect(await eventually { firstRecentBranch() == "same-sha" })
    }
}
