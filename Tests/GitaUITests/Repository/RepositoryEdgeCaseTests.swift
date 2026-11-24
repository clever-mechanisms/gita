import AppKit
import GitaCore
import Testing

@testable import GitaUI

/// The repository window's rarer paths: long histories, agents in a checkout, linked worktrees, remotes and saved
/// commit message drafts.
@MainActor
@Suite("Repository window · edge cases", .serialized)
struct RepositoryEdgeCaseTests {
    private static func session(
        _ id: String, state: AgentState, at checkout: URL, subagent: Bool = false
    ) -> AgentSession {
        AgentSession(
            id: id, tool: .claudeCode, pid: 1, workingDirectory: checkout, checkoutRoot: checkout,
            repositoryRoot: checkout, branch: "main", state: state, stateSince: .distantPast,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000), evidence: .hook, title: "Fix the tests",
            isSubagent: subagent, parentID: subagent ? "lead" : nil)
    }

    /// `count` commits on main, written in one `git fast-import`.
    private static func longHistory(_ count: Int) -> (TemporaryRepository) throws -> Void {
        { repository in
            var stream = ""
            for index in 1...count {
                let message = "Commit \(index)"
                stream += "commit refs/heads/main\nmark :\(index)\n"
                stream += "committer Gita Tests <tests@example.invalid> \(1_700_000_000 + index) +0000\n"
                stream += "data \(message.utf8.count)\n\(message)\n"
                if index > 1 { stream += "from :\(index - 1)\n" }
                stream += "M 644 inline file.txt\ndata \(String(index).utf8.count)\n\(index)\n\n"
            }
            let input = repository.url.appendingPathComponent("import.txt")
            try Data(stream.utf8).write(to: input)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["fast-import", "--quiet"]
            process.currentDirectoryURL = repository.url
            process.standardInput = try FileHandle(forReadingFrom: input)
            try process.run()
            process.waitUntilExit()
            try FileManager.default.removeItem(at: input)
            try repository.git("reset", "-q", "--hard", "main")
        }
    }

    @Test func scrollingNearTheBottomReadsTheNextPage() async throws {
        let fixture = try await RepositoryWindowFixture(prepare: Self.longHistory(520))
        defer { fixture.close() }
        let controller = fixture.controller
        #expect(controller.historyCommits.count == 500)
        #expect(fixture.model.displayedHistoryHasMore)
        let table = fixture.historyTable
        table.scrollRowToVisible(table.numberOfRows - 1)
        controller.loadHistoryNearBottom()
        try await fixture.wait("the next page") { controller.historyCommits.count == 520 }
        #expect(!fixture.model.displayedHistoryHasMore)
        // The same page is never read twice.
        controller.loadHistoryNearBottom()
        controller.moreHistory()
    }

    @Test func agentChipsAndTheStripsAgentCell() throws {
        UITestSupport.bootstrap()
        let checkout = URL(fileURLWithPath: "/tmp/fixture")
        let lead = Self.session("lead", state: .needsInput, at: checkout)
        let other = Self.session("other", state: .working, at: checkout)
        let sub = Self.session("sub", state: .working, at: checkout, subagent: true)
        let chip = HistoryChips.agents([lead, other, sub])
        #expect(chip?.label.contains("+") == true)
        #expect(chip?.tooltip.contains("subagents") == true)
        #expect(HistoryChips.agents([]) == nil)
        #expect(HistoryChips.agents([sub])?.label.hasPrefix("Subagent") == true)

        var input = WorktreeStripView.Input()
        #expect(WorktreeStripCells.agent(input) == nil)
        input.session = lead
        let alone = try #require(WorktreeStripCells.agent(input, now: Date(timeIntervalSince1970: 1_700_003_600)))
        #expect(alone.click == .agent(lead))
        input.otherAgents = 1
        input.subagents = 2
        let crowd = try #require(WorktreeStripCells.agent(input))
        #expect(crowd.click == .agent(nil))
        #expect(crowd.detail.contains("2 agents"))

        let strip = WorktreeStripView(frame: NSRect(x: 0, y: 0, width: 900, height: 34))
        var events: [String] = []
        strip.onAgent = { events.append("agent \($0?.id ?? "-")") }
        strip.onFetch = { events.append("fetch") }
        strip.onCreatePullRequest = { events.append("pr") }
        strip.onChecks = { events.append("checks") }
        strip.open = { events.append("open \($0.host ?? "")") }
        for click in [
            StripCellContent.Click.none, .agent(lead), .fetch, .createPullRequest, .checks,
            .open(ProviderSamples.web("https://example.com")),
        ] {
            strip.perform(click, from: strip)
        }
        #expect(events == ["agent lead", "fetch", "pr", "checks", "open example.com"])
        strip.update(input)
        UITestSupport.render(strip)
    }

    @Test func aMergeRowsTooltips() {
        UITestSupport.bootstrap()
        let commit = GitCommit(
            id: "m", parents: ["a", "b"], subject: "Merge", author: "Ada", email: "a@example.invalid", date: Date(),
            decorations: (1...8).map { "refs/heads/branch-\($0)" })
        let cell = HistoryCommitCell(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        cell.configure(
            HistoryCommitCell.Content(
                commit: commit, row: GraphRow(lane: 0, color: 0, incoming: [], outgoing: []), scale: 1,
                isHead: false, remoteNames: [],
                merge: MergeFlair(
                    mergedBy: "Ada", email: "a@example.invalid", count: "2 commits", tooltip: "Merged by Ada",
                    expanded: true)))
        cell.layoutSubtreeIfNeeded()
        UITestSupport.render(cell)
        var tips = Set<String>()
        for x in stride(from: CGFloat(0), through: 300, by: 4) {
            tips.insert(cell.view(cell, stringForToolTip: 0, point: NSPoint(x: x, y: 12), userData: nil))
        }
        #expect(tips.count > 1)
    }

    @Test func sidebarClicksToggleRepositoriesRemotesAndFolders() async throws {
        let fixture = try await RepositoryWindowFixture { repository in
            try RepositoryWindowFixture.mergedFeature(repository)
            try repository.git("remote", "add", "origin", "https://example.invalid/fixture.git")
            try repository.git("remote", "add", "upstream", "https://example.invalid/upstream.git")
            try repository.git("update-ref", "refs/remotes/origin/main", "main")
            try repository.git("update-ref", "refs/remotes/origin/feature/login", "feature/login")
            try repository.git("update-ref", "refs/remotes/upstream/main", "main")
            try repository.git("symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main")
        }
        defer { fixture.close() }
        let sidebar = fixture.controller.sidebarView
        func index(_ match: (RepositorySidebarView.Row) -> Bool) -> Int? { sidebar.rows.firstIndex(where: match) }
        let remotes = try #require(
            index { if case .nav(let nav) = $0 { nav.target == .group(.remotes) } else { false } })
        sidebar.click(remotes)
        let origin = try #require(index { if case .remote(let name, _, _, _) = $0 { name == "origin" } else { false } })
        sidebar.secondClick(origin)
        sidebar.secondClick(origin)
        #expect(index { if case .remote(let name, _, _, _) = $0 { name == "upstream" } else { false } } != nil)
        if let folder = index({ if case .folder = $0 { true } else { false } }) {
            sidebar.secondClick(folder)
        }
        sidebar.secondClick(remotes)
        let repository = try #require(index { if case .repository = $0 { true } else { false } })
        sidebar.click(repository)
        sidebar.secondClick(repository)
        sidebar.secondClick(0)
        sidebar.click(-1)
        for row in sidebar.rows.indices {
            _ = sidebar.tableView(sidebar.repositoryPane.list.table, viewFor: nil, row: row)
        }
        sidebar.repositoryPane.filter.stringValue = "upstream"
        sidebar.filterChanged()
        #expect(index { if case .remote(let name, _, _, _) = $0 { name == "upstream" } else { false } } != nil)
    }

    @Test func aLinkedWorktreeListsAsItsRepositorysCheckout() {
        let main = URL(fileURLWithPath: "/tmp/fixture")
        let linked = URL(fileURLWithPath: "/tmp/fixture-tree")
        let snapshot = RepositorySnapshot(
            root: linked, branch: "side", head: "abc", ahead: 1, changes: [], commits: [], references: [],
            worktrees: [
                GitWorktree(path: main.path, branch: "refs/heads/main", head: "def"),
                GitWorktree(path: linked.path, branch: "refs/heads/side", head: "abc"),
            ],
            stashes: [], remoteURL: nil, gitDirectory: linked.appendingPathComponent(".git"))
        let list = SidebarRepositoryList(
            snapshot: snapshot, statuses: [], status: { _ in nil }, openRepositories: [linked], recent: [main.path],
            loading: [linked.path], key: { $0?.standardizedFileURL.path }, sessionsAt: { _ in [] },
            sessionsIn: { _ in [] })
        let repositories = list.repositories()
        #expect(repositories.count == 1)
        #expect(repositories.first?.checkouts.map(\.path) == [main.path, linked.path])
        #expect(repositories.first?.checkouts.last?.isLoading == true)
        #expect(repositories.first?.checkouts.last?.meta == "↑1")
        #expect(SidebarRepositoryList.badge(ahead: 0, changed: 3) == "3 changed")
    }

    @Test func draftsAreSavedReadAndRefusedWhenUnsafe() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GitaUITests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("repository")
        let draft = try CommitMessageDraft.open(
            root: root, gitDirectory: root.appendingPathComponent(".git"), in: directory)
        draft.setText("Work in progress")
        try draft.flush()
        let file = directory.appendingPathComponent(
            CommitMessageDraft.identity(root: root, gitDirectory: root.appendingPathComponent(".git")) + ".txt")
        #expect(try String(contentsOf: file, encoding: .utf8) == "Work in progress")
        draft.setText("")
        try draft.flush()
        #expect(!FileManager.default.fileExists(atPath: file.path))

        func open(_ name: String) throws -> CommitMessageDraft {
            let other = directory.appendingPathComponent(name)
            return try CommitMessageDraft.open(root: other, gitDirectory: other, in: directory)
        }
        func draftFile(_ name: String) -> URL {
            let other = directory.appendingPathComponent(name)
            return directory.appendingPathComponent(
                CommitMessageDraft.identity(root: other, gitDirectory: other) + ".txt")
        }
        try Data("saved".utf8).write(to: draftFile("saved"))
        #expect(try open("saved").text == "saved")
        try Data([0xFF, 0xFE, 0xFD]).write(to: draftFile("binary"))
        #expect(throws: (any Error).self) { try open("binary") }
        try FileManager.default.createDirectory(at: draftFile("folder"), withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try open("folder") }
        try FileManager.default.createSymbolicLink(at: draftFile("link"), withDestinationURL: draftFile("saved"))
        #expect(throws: (any Error).self) { try open("link") }
        try Data(count: 1_048_577).write(to: draftFile("large"))
        #expect(throws: (any Error).self) { try open("large") }
    }
}
