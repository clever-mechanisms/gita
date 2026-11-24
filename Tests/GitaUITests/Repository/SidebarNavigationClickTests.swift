import AppKit
import GitaCore
import Testing

@testable import GitaUI

@MainActor
@Suite("Repository sidebar · unified 1-click navigation matrix", .serialized)
struct SidebarNavigationClickTests {
    private func makeDefaults() throws -> (defaults: UserDefaults, suite: String) {
        let suite = "GitaUITests.sidebarClicks.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (defaults, suite)
    }

    private struct FixtureSidebar {
        var sidebar: RepositorySidebarView
        var mainURL: URL
        var treeURL: URL
        var otherURL: URL
    }

    private func makeSidebar(defaults: UserDefaults) -> FixtureSidebar {
        let state = SidebarState.shared(defaults)
        let sidebar = RepositorySidebarView(state: state)
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
        let mainURL = URL(fileURLWithPath: "/tmp/repo-main", isDirectory: true)
        let treeURL = URL(fileURLWithPath: "/tmp/repo-tree", isDirectory: true)
        let otherURL = URL(fileURLWithPath: "/tmp/other-repo", isDirectory: true)
        var input = RepositorySidebarView.Input()
        input.currentRoot = mainURL
        input.currentName = "repo-main"
        input.references = [
            GitReference(name: "main", fullName: "refs/heads/main", commit: "111", kind: .branch, isCurrent: true),
            GitReference(
                name: "feature/wt", fullName: "refs/heads/feature/wt", commit: "222", kind: .branch, isCurrent: false),
            GitReference(name: "v1.0", fullName: "refs/tags/v1.0", commit: "111", kind: .tag),
        ]
        input.worktreeBranches = ["feature/wt": treeURL.path]
        input.stashes = [GitStash(ref: "stash@{0}", subject: "WIP")]
        input.repositories = [
            RepositorySidebarView.Repository(
                root: mainURL, name: "repo-main", badge: "", badgeIsChange: false, isCurrent: true,
                checkouts: [
                    RepositorySidebarView.Checkout(
                        path: mainURL.path, branch: "main", sessions: [], meta: "", isMain: true),
                    RepositorySidebarView.Checkout(
                        path: treeURL.path, branch: "feature/wt", sessions: [], meta: "", isMain: false),
                ]),
            RepositorySidebarView.Repository(
                root: otherURL, name: "other-repo", badge: "", badgeIsChange: false, isCurrent: false,
                checkouts: [
                    RepositorySidebarView.Checkout(
                        path: otherURL.path, branch: "main", sessions: [], meta: "", isMain: true)
                ]),
        ]
        sidebar.update(input)
        sidebar.layoutSubtreeIfNeeded()
        return FixtureSidebar(sidebar: sidebar, mainURL: mainURL, treeURL: treeURL, otherURL: otherURL)
    }

    @Test func clickDoubleClickAndCommandClickBehaveConsistentlyAcrossEveryRow() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = makeSidebar(defaults: defaults)
        let sidebar = fixture.sidebar
        let (mainURL, treeURL, otherURL) = (fixture.mainURL, fixture.treeURL, fixture.otherURL)

        var opened: [URL] = []
        var openedTabs: [URL] = []
        var pages: [SidebarSelection] = []
        var refs: [String] = []
        var stashes: [String] = []
        sidebar.onOpenCheckout = { opened.append($0) }
        sidebar.onOpenInNewTab = { openedTabs.append($0) }
        sidebar.onNavigate = { pages.append($0) }
        sidebar.onReference = { refs.append($0.fullName) }
        sidebar.onStash = { stashes.append($0.ref) }

        func rowIndex(_ match: (RepositorySidebarView.Row) -> Bool) throws -> Int {
            let found = sidebar.rows.firstIndex(where: match)
            return try #require(found)
        }

        // Single click & double click on checkout open it; Cmd-click opens new tab.
        let treeCheckout = try rowIndex {
            if case .checkout(let checkout, _, _) = $0 { checkout.path == treeURL.path } else { false }
        }
        sidebar.click(treeCheckout)
        sidebar.secondClick(treeCheckout)
        #expect(opened.map(\.path) == [treeURL.path, treeURL.path])

        sidebar.currentModifiers = { .command }
        sidebar.click(treeCheckout)
        #expect(openedTabs.map(\.path) == [treeURL.path])
        sidebar.currentModifiers = { [] }

        // Collapsed multi-checkout repository opens main/MRU checkout and expands on single click; Cmd-click opens tab.
        SidebarState.shared(defaults).repositoryExpansion[mainURL.path] = false
        sidebar.repositoriesPane.rebuild()
        let repoRow = try rowIndex {
            if case .repository(let repo, _) = $0 { repo.root == mainURL } else { false }
        }
        sidebar.click(repoRow)
        if case .repository(_, let expanded) = sidebar.rows[repoRow] {
            #expect(expanded)
        } else {
            Issue.record("Expected repository row")
        }
        #expect(opened.last?.path == mainURL.path)

        let otherRow = try rowIndex {
            if case .repository(let repo, _) = $0 { repo.root == otherURL } else { false }
        }
        sidebar.currentModifiers = { .command }
        sidebar.click(otherRow)
        #expect(openedTabs.last?.path == otherURL.path)
        sidebar.currentModifiers = { [] }

        // Pages, branches, tags, stashes all open on 1 click; Cmd-click on worktree branch opens new tab.
        let changesRow = try rowIndex {
            if case .nav(let nav) = $0 { nav.target == .page(.changes) } else { false }
        }
        sidebar.click(changesRow)
        #expect(pages == [.changes])

        let mainBranchRow = try rowIndex {
            if case .reference(let ref) = $0 { ref.reference.fullName == "refs/heads/main" } else { false }
        }
        sidebar.click(mainBranchRow)
        #expect(refs == ["refs/heads/main"])

        let wtBranchRow = try rowIndex {
            if case .reference(let ref) = $0 { ref.reference.fullName == "refs/heads/feature/wt" } else { false }
        }
        sidebar.currentModifiers = { .command }
        sidebar.click(wtBranchRow)
        #expect(openedTabs.last?.path == treeURL.path)
        sidebar.currentModifiers = { [] }

        let stashesGroup = try rowIndex {
            if case .nav(let nav) = $0 { nav.target == .group(.stashes) } else { false }
        }
        sidebar.click(stashesGroup)
        let stashRow = try rowIndex { if case .stash = $0 { true } else { false } }
        sidebar.click(stashRow)
        #expect(stashes == ["stash@{0}"])
    }

    @Test func chevronHitAndArrowKeysToggleExpansionWithoutOpeningAndPreserveSelection() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = makeSidebar(defaults: defaults)
        let (sidebar, mainURL) = (fixture.sidebar, fixture.mainURL)

        var opened: [URL] = []
        sidebar.onOpenCheckout = { opened.append($0) }

        let repoLocalRow = try #require(
            sidebar.repositoriesPane.rows.firstIndex {
                if case .repository(let repo, _) = $0 { repo.root == mainURL } else { false }
            })
        let repoTable = sidebar.repositoriesPane.list.table
        let cell = try #require(
            sidebar.repositoriesPane.list.tableView(repoTable, viewFor: nil, row: repoLocalRow) as? SidebarCell)
        cell.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
        cell.layoutSubtreeIfNeeded()
        #expect(cell.isChevronHit(at: NSPoint(x: cell.chevron.frame.midX, y: cell.chevron.frame.midY)))
        #expect(!cell.isChevronHit(at: NSPoint(x: cell.title.frame.midX, y: cell.title.frame.midY)))

        // Arrow keys Left / Right toggle expansion on repository row while keeping it selected and without opening.
        repoTable.selectRowIndexes(IndexSet(integer: repoLocalRow), byExtendingSelection: false)
        repoTable.keyDown(with: try #require(SharedEvents.key("", code: KeyPress.leftArrow)))
        if case .repository(_, let expanded) = sidebar.repositoriesPane.rows[repoLocalRow] {
            #expect(!expanded)
        }
        #expect(repoTable.selectedRow == repoLocalRow)
        #expect(opened.isEmpty)

        repoTable.keyDown(with: try #require(SharedEvents.key("", code: KeyPress.rightArrow)))
        if case .repository(_, let expanded) = sidebar.repositoriesPane.rows[repoLocalRow] {
            #expect(expanded)
        }
        #expect(repoTable.selectedRow == repoLocalRow)
        #expect(opened.isEmpty)
    }
}
