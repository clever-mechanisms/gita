import AppKit
import GitaCore
import Testing

@testable import GitaUI

/// The repository window's value types, without a window.
@MainActor
@Suite("Repository presenters")
struct RepositoryPresenterTests {
    private static func commit(_ id: String, _ parents: [String]) -> GitCommit {
        GitCommit(id: id, parents: parents, subject: id, author: "Ada", email: "a@example.invalid", date: .distantPast)
    }

    private static func snapshot(
        head: String?, ahead: Int, commits: [GitCommit], remotes: [String: String] = [:], branch: String = "main"
    ) -> RepositorySnapshot {
        RepositorySnapshot(
            root: URL(fileURLWithPath: "/tmp/fixture"), branch: branch, head: head, ahead: ahead, changes: [],
            commits: commits,
            references: remotes.map {
                GitReference(name: $0.key, fullName: "refs/remotes/" + $0.key, commit: $0.value, kind: .remote)
            },
            worktrees: [], stashes: [], remoteURL: nil, gitDirectory: URL(fileURLWithPath: "/tmp/fixture/.git"))
    }

    @Test func unpushedCommitsStopAtTheRemoteAndTheAheadCount() {
        let commits = [
            Self.commit("c", ["b"]), Self.commit("b", ["a"]), Self.commit("a", ["root"]), Self.commit("root", []),
        ]
        var unpushed = UnpushedCommits()
        let remote = ["origin/main": "a"]
        var changed = unpushed.update(Self.snapshot(head: "c", ahead: 2, commits: commits, remotes: remote))
        #expect(changed)
        #expect(unpushed.ids == ["c", "b"])
        // Nothing moved: no walk, no change.
        changed = unpushed.update(Self.snapshot(head: "c", ahead: 2, commits: commits, remotes: remote))
        #expect(!changed)
        changed = unpushed.update(Self.snapshot(head: "c", ahead: 1, commits: commits, remotes: remote))
        #expect(changed)
        #expect(unpushed.ids == ["c"])
        changed = unpushed.update(Self.snapshot(head: "c", ahead: 0, commits: commits))
        #expect(changed)
        #expect(unpushed.ids.isEmpty)
        changed = unpushed.update(nil)
        #expect(!changed)
        #expect(UnpushedCommits.walk(commits, from: "c", remoteTips: [], limit: 10) == ["c", "b", "a", "root"])
    }

    @Test func destructiveConfirmationListsTwelvePaths() {
        UITestSupport.bootstrap()
        let paths = (1...14).map { "file\($0).txt" }
        let list = DestructiveConfirmation.pathList(paths)
        #expect(list.split(separator: "\n").count == 13)
        #expect(list.hasSuffix("…"))
        #expect(DestructiveConfirmation.pathList(["a"]) == "a")
        let alert = DestructiveConfirmation(message: "Discard Changes?", detail: list, action: "Discard").alert()
        #expect(alert.buttons.map(\.title) == ["Discard", "Cancel"])
        #expect(alert.buttons[0].hasDestructiveAction)
        #expect(alert.buttons.map(\.keyEquivalent) == ["", "\u{1b}"])
    }

    @Test func discardNoteCountsUntrackedFiles() {
        #expect(DestructiveConfirmation.untrackedNote(0) == nil)
        #expect(
            DestructiveConfirmation.untrackedNote(1) == String(localized: "The untracked file is deleted permanently."))
        #expect(DestructiveConfirmation.untrackedNote(3)?.contains("3") == true)
    }

    @Test func worktreeRemovalNamesWorkingAgentsAsOneSentence() {
        #expect(DestructiveConfirmation.workingAgentsNote([]) == nil)
        #expect(
            DestructiveConfirmation.workingAgentsNote(["Codex"]) == String(localized: "\("Codex") is working here."))
        let names = ["Claude Code", "Codex", "Gemini"]
        let list = ListFormatter.localizedString(byJoining: names)
        #expect(DestructiveConfirmation.workingAgentsNote(names) == String(localized: "\(list) are working here."))
        #expect(names.allSatisfy(list.contains) && list != names.joined(separator: ", "))
    }

    @Test func branchFiltersToggleAndPersistPerRepository() throws {
        let suite = "GitaUITests.filters.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var filters = BranchFilters()
        filters.toggle(.hide, "refs/heads/a")
        filters.toggle(.only, "refs/heads/a")
        #expect(filters.only == ["refs/heads/a"])
        #expect(filters.hidden.isEmpty)
        filters.toggle(.hide, "refs/heads/a")
        #expect(filters.only.isEmpty)
        filters.toggle(.pin, "refs/heads/b")
        #expect(filters.contains(.pin, "refs/heads/b"))
        #expect(filters.contains(.hide, "refs/heads/a"))
        #expect(!filters.contains(.only, "refs/heads/a"))
        #expect(filters.isFiltering)
        let repository = URL(fileURLWithPath: "/tmp/repository")
        filters.save(repository, to: defaults)
        #expect(BranchFilters.load(repository, from: defaults) == filters)
        BranchFilters().save(repository, to: defaults)
        #expect(BranchFilters.load(repository, from: defaults) == BranchFilters())
        _ = filters.scope
    }

    @Test func theScrollMemoryReturnsToAllCommits() {
        var memory = HistoryScrollMemory()
        let focused = HistoryMode.focused(UUID())
        var origin = memory.origin(for: .all, current: CGPoint(x: 0, y: 50), rowHeight: 24)
        #expect(origin == CGPoint(x: 0, y: 50))
        origin = memory.origin(for: focused, current: CGPoint(x: 0, y: 240), rowHeight: 24)
        #expect(origin == .zero)
        origin = memory.origin(for: .all, current: .zero, rowHeight: 48)
        #expect(origin == CGPoint(x: 0, y: 480))
        #expect(HistoryMode(searchQuery: "x", field: .message, focusedIdentity: nil).isSearch)
    }

    @Test func listUpdatesKeepAppendOrReload() {
        let mode = HistoryMode.all
        let signature = HistoryListState.Signature(mode: mode, head: "c", remoteNames: [], squashRevision: 0)
        let one = HistoryListState(signature: signature, commits: [Self.commit("c", [])], graphs: [])
        let two = HistoryListState(
            signature: signature, commits: [Self.commit("c", []), Self.commit("b", [])], graphs: [])
        #expect(HistoryListUpdate.plan(from: nil, to: one, graphCanChange: false) == .reload)
        #expect(HistoryListUpdate.plan(from: one, to: one, graphCanChange: false) == .unchanged)
        #expect(HistoryListUpdate.plan(from: one, to: two, graphCanChange: false) == .append)
        var moved = two
        moved.signature.head = "b"
        #expect(HistoryListUpdate.plan(from: one, to: moved, graphCanChange: false) == .reload)
        #expect(HistoryListUpdate.plan(from: two, to: one, graphCanChange: false) == .reload)
    }

    @Test func pagesAndSections() {
        #expect(SectionRoute(.settings) == .window(.settings))
        #expect(SectionRoute(.worktrees) == .agentsPane)
        #expect(SectionRoute(.history) == .page(.history))
        #expect(SectionPanes(.changes).showsCommitFooter)
        #expect(!SectionPanes(.pullRequests).showsHistoryPane)
        let state = ProviderPageState(
            section: .workflows, signals: [], reports: [ProviderSamples.disconnected(.github)])
        #expect(state.emptyMessage != "No workflow runs")
        #expect(state.statusToolTip == "Run gh auth login")
        let connected = ProviderPageState(
            section: .deployments, signals: ProviderSamples.vercel(head: "h", branch: "main").items,
            reports: [ProviderSamples.vercel(head: "h", branch: "main")])
        #expect(connected.items.count == 2)
        #expect(connected.emptyMessage == "No deployments")
        #expect(!ProviderPageState.lists(connected.items[0], on: .history))
    }

    @Test func remoteBranchNames() {
        let references = [
            GitReference(
                name: "upstream/feature/x", fullName: "refs/remotes/upstream/feature/x", commit: "a", kind: .remote),
            GitReference(
                name: "origin/feature/x", fullName: "refs/remotes/origin/feature/x", commit: "a", kind: .remote),
            GitReference(name: "origin/HEAD", fullName: "refs/remotes/origin/HEAD", commit: "a", kind: .remote),
        ]
        #expect(RemoteBranchName.remote(of: "feature/x", in: references) == "origin/feature/x")
        #expect(RemoteBranchName.remote(of: "x", in: references) == nil)
        #expect(RemoteBranchName.remoteName(references[0]) == "upstream")
        #expect(RemoteBranchName.branchName(references[0]) == "feature/x")
        #expect(RemoteBranchName.remotes(in: references) == ["origin", "upstream"])
    }

    @Test func paneGeometryKeepsHistoryRoom() {
        var panes = PaneState()
        #expect(panes.historyDivider(height: 1_000) == 732)
        #expect(panes.historyDivider(height: 200) == 150)
        #expect(PaneState.detailHeight(1_000, divider: 1) == 600)
        #expect(PaneState.detailHeight(10, divider: 1) == 150)
        panes.agentsPaneWidth = 500
        #expect(panes.agentsWidth(total: 1_000, leading: 200, divider: 1) == 379)
        #expect(panes.agentsWidth(total: 600, leading: 200, divider: 1) == 260)
    }

    @Test func aCommitsFileReference() {
        let commit = GitCommit(
            id: "0123456789abcdef", parents: ["p1"], subject: "s", author: "a", email: "e", date: Date())
        let reference = CommitFileReference(commit: commit, stash: nil, comparisonBase: nil)
        #expect(reference?.short == "0123456")
        #expect(reference?.before == "p1")
        #expect(CommitFileReference(commit: nil, stash: nil, comparisonBase: nil) == nil)
    }
}
