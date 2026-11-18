import Foundation
import Testing

@testable import GitaCore
@testable import GitaUI

private func commit(_ id: String, _ parents: [String] = [], author: String = "A", email: String = "") -> GitCommit {
    GitCommit(id: id, parents: parents, subject: id, author: author, email: email, date: Date(timeIntervalSince1970: 0))
}

private func snapshot(
    commits: [GitCommit] = [], references: [GitReference] = [], stashes: [GitStash] = [],
    operation: GitOperationState? = nil, historyIdentity: UUID? = nil, ancestryIdentity: String? = nil
) -> RepositorySnapshot {
    RepositorySnapshot(
        root: URL(fileURLWithPath: "/tmp/repository"), branch: "main", head: commits.first?.id, changes: [],
        commits: commits, references: references, worktrees: [], stashes: stashes, remoteURL: nil,
        gitDirectory: URL(fileURLWithPath: "/tmp/repository/.git"), historyIdentity: historyIdentity,
        ancestryIdentity: ancestryIdentity, operation: operation)
}

@Suite("Model value types")
struct ModelValueTests {
    // MARK: RefreshPlan

    /// The review before a refresh: the History page with nothing selected, changed by `change`.
    private func before(_ change: (inout RefreshPlan.Before) -> Void = { _ in }) -> RefreshPlan.Before {
        var value = RefreshPlan.Before(
            section: .history, operationIdentity: nil, historyIdentity: nil, ancestryIdentity: nil, commit: nil,
            stash: nil, hasCommitDetails: false, isTreeReview: false, focusedFirst: nil, isFocused: false,
            isSearching: false)
        change(&value)
        return value
    }

    private func reselection(
        _ next: RepositorySnapshot, _ change: (inout RefreshPlan.Before) -> Void = { _ in }
    )
        -> RefreshPlan.Reselection
    {
        RefreshPlan(before: before(change), next: next).reselection
    }

    @Test func refreshPlanReselections() {
        let first = commit("a")
        let second = commit("b")
        let stash = GitStash(ref: "stash@{0}", subject: "WIP")
        let history = UUID()
        let next = snapshot(
            commits: [first, second], stashes: [stash], historyIdentity: history, ancestryIdentity: "x")
        var decorated = second
        decorated.decorations = ["tag"]

        #expect(reselection(next) { $0.section = .changes } == .refreshChanges(unstage: false))
        #expect(reselection(next) { $0.stash = stash } == .stash(stash))
        #expect(reselection(next) == .select(first))
        #expect(reselection(snapshot()) == .nothing)
        #expect(
            reselection(next) {
                $0.focusedFirst = second
                $0.isFocused = true
            } == .select(second))
        #expect(reselection(next) { $0.commit = second } == .select(second))
        func reviewed(_ commit: GitCommit) -> (inout RefreshPlan.Before) -> Void {
            { value in
                value.commit = commit
                value.hasCommitDetails = true
                value.ancestryIdentity = "x"
            }
        }
        #expect(reselection(next, reviewed(second)) == .keep(second, notify: false))
        #expect(reselection(next, reviewed(decorated)) == .keep(second, notify: true))
        #expect(
            reselection(next) {
                reviewed(second)(&$0)
                $0.ancestryIdentity = "y"
            } == .select(second))
        #expect(
            reselection(next) {
                reviewed(second)(&$0)
                $0.isTreeReview = true
                $0.historyIdentity = history
            } == .keep(second, notify: true))
        #expect(
            reselection(next) {
                reviewed(second)(&$0)
                $0.isTreeReview = true
            } == .select(second))
    }

    @Test func aNewOperationShowsTheChangesPage() {
        let next = snapshot(commits: [commit("a")], operation: GitOperationState(kind: .merge, identity: "m"))
        #expect(reselection(next) == .enterChanges)
        #expect(reselection(next) { $0.section = .changes } == .refreshChanges(unstage: true))
        #expect(reselection(next) { $0.operationIdentity = "m" } == .select(commit("a")))
    }

    @Test func refreshPlanSearchAndFocus() {
        let next = snapshot(commits: [commit("a")], historyIdentity: UUID(), ancestryIdentity: "new")
        func focused(ancestry: String, section: GitaUI.Section = .history) -> RefreshPlan.Before {
            before {
                $0.isFocused = true
                $0.ancestryIdentity = ancestry
                $0.section = section
            }
        }
        var searching = focused(ancestry: "old")
        searching.isSearching = true
        let plan = RefreshPlan(before: searching, next: next)
        #expect(plan.restartsSearch)
        #expect(plan.focus == .refocus)
        #expect(RefreshPlan(before: focused(ancestry: "old", section: .changes), next: next).focus == .discard)
        let same = RefreshPlan(before: focused(ancestry: "new"), next: next)
        #expect(same.focus == .none)
        #expect(!same.restartsSearch)
    }

    // MARK: Provider refresh policy

    @Test func providerRefreshPolicy() {
        let now = Date()
        #expect(ProviderRefreshPolicy.minuteTickRefreshes(foreground: true, pending: false, lastStarted: now, now: now))
        #expect(ProviderRefreshPolicy.minuteTickRefreshes(foreground: false, pending: true, lastStarted: now, now: now))
        #expect(
            ProviderRefreshPolicy.minuteTickRefreshes(foreground: false, pending: false, lastStarted: nil, now: now))
        #expect(
            !ProviderRefreshPolicy.minuteTickRefreshes(foreground: false, pending: false, lastStarted: now, now: now))
        #expect(
            ProviderRefreshPolicy.minuteTickRefreshes(
                foreground: false, pending: false, lastStarted: now.addingTimeInterval(-200), now: now))

        #expect(ProviderRefreshPolicy.onBecomingVisible(lastStarted: nil, agentsCheckedAt: nil, now: now) == .all)
        #expect(ProviderRefreshPolicy.onBecomingVisible(lastStarted: now, agentsCheckedAt: nil, now: now) == .agents)
        #expect(ProviderRefreshPolicy.onBecomingVisible(lastStarted: now, agentsCheckedAt: now, now: now) == .none)

        let running = ProviderItem(
            id: "d", provider: .vercel, category: "", title: "", state: .running, kind: .deployment)
        let done = ProviderItem(
            id: "r", provider: .github, category: "", title: "", state: .success, kind: .workflowRun)
        #expect(ProviderRefreshPolicy.hasPendingSignals([running]))
        #expect(!ProviderRefreshPolicy.hasPendingSignals([done]))
        #expect(
            ProviderRefreshPolicy.vercelInFlight([
                ProviderReport(provider: .vercel, items: [running], status: .connected)
            ]))
        #expect(
            !ProviderRefreshPolicy.vercelInFlight([
                ProviderReport(provider: .github, items: [running], status: .connected)
            ]))
        #expect(SignalState.pending.isInFlight)
        #expect(!SignalState.failure.isInFlight)
    }

    // MARK: Provider details cache

    @Test func providerDetailsCacheKeepsRecentEntriesForTheSameItem() {
        var cache = ProviderDetailsCache()
        let now = Date()
        func item(_ id: Int, provider: ProviderKind = .github) -> (ProviderItem, ProviderTarget) {
            let target = ProviderTarget.pullRequest(repository: "o/r", number: id)
            return (
                ProviderItem(id: "\(id)", provider: provider, category: "", title: "", state: .neutral, target: target),
                target
            )
        }
        let (first, target) = item(1)
        cache.store(ProviderDetailReport(target: target, status: .connected), for: target, item: first, now: now)
        #expect(cache.report(for: target, item: first, now: now)?.status == .connected)
        #expect(
            cache.report(for: target, item: first, now: now.addingTimeInterval(ProviderDetailsCache.lifetime)) == nil)
        #expect(cache.report(for: target, item: first, now: now.addingTimeInterval(-1)) == nil)
        var changed = first
        changed.title = "changed"
        #expect(cache.report(for: target, item: changed, now: now) == nil)

        for index in 2...(ProviderDetailsCache.capacity + 1) {
            let (other, otherTarget) = item(index)
            cache.store(
                ProviderDetailReport(target: otherTarget, status: .connected), for: otherTarget, item: other,
                now: now.addingTimeInterval(TimeInterval(index)))
        }
        #expect(cache.report(for: target, item: first, now: now) == nil) // the oldest went

        let (kept, keptTarget) = item(5)
        cache.retain(listedIn: ProviderReport(provider: .github, items: [kept], status: .connected))
        #expect(cache.report(for: keptTarget, item: kept, now: now.addingTimeInterval(5)) != nil)
        let (gone, goneTarget) = item(6)
        #expect(cache.report(for: goneTarget, item: gone, now: now.addingTimeInterval(6)) == nil)

        let epoch = cache.epoch
        cache.remove(provider: .github)
        #expect(cache.report(for: keptTarget, item: kept, now: now.addingTimeInterval(5)) == nil)
        cache.removeAll()
        #expect(cache.epoch == epoch + 2)
    }

    // MARK: History pages and graph input

    @Test func historyPages() {
        let page = (0...HistoryPage.size).map { commit("c\($0)") }
        #expect(HistoryPage.request == HistoryPage.size + 1)
        #expect(HistoryPage.hasMore(page))
        #expect(!HistoryPage.hasMore(Array(page.prefix(3))))
        #expect(HistoryPage.added(page, known: ["c0": 0]).count == HistoryPage.size - 1)
        // Further pages are larger: a page of the first page's size is their last.
        #expect(HistoryPage.further > HistoryPage.size)
        #expect(!HistoryPage.hasMore(page, size: HistoryPage.further))
        #expect(HistoryPage.added(page, known: [:], size: HistoryPage.further).count == page.count)
        #expect(HistoryPage.rows([commit("a"), commit("b"), commit("a")]) == ["a": 0, "b": 1])

        let identity = UUID()
        let old = snapshot(commits: page, historyIdentity: identity)
        let next = snapshot(commits: Array(page.prefix(HistoryPage.size)), historyIdentity: identity)
        #expect(HistoryPage.keepsLoadedPages(old, next))
        #expect(!HistoryPage.keepsLoadedPages(old, snapshot(commits: Array(page.prefix(HistoryPage.size)))))
        #expect(!HistoryPage.keepsLoadedPages(next, next))
    }

    @Test func historyGraphInputLinksSquashTipsAndLensParents() {
        let commits = [commit("squash", ["base"]), commit("tip", ["base"]), commit("base")]
        #expect(HistoryGraphInput.make(commits, squashLinks: [:]) == commits)
        let linked = HistoryGraphInput.make(commits, squashLinks: ["squash": "tip", "base": "tip"])
        #expect(linked[0].parents == ["base", "tip"])
        #expect(linked[2].parents.isEmpty) // the tip comes before it: no link
        let lens = HistoryGraphInput.lens(commits, links: ["squash": ["base"]])
        #expect(lens.map(\.parents) == [["base"], [], []])
    }

    @Test func historyGraphStateKeysAndResets() {
        let reference = GitReference(name: "main", fullName: "refs/heads/main", commit: "abc", kind: .branch)
        let key = HistoryGraphState.squashKey(snapshot(commits: [commit("h")], references: [reference]))
        #expect(key == "h|refs/heads/main abc")
        var state = HistoryGraphState()
        state.squashLinks = ["a": "b"]
        state.expandedMerges = ["m"]
        state.squashSearch = .found(key: key)
        state.reset()
        #expect(state.squashLinks.isEmpty)
        #expect(state.expandedMerges.isEmpty)
        #expect(state.squashSearch.key == nil)
        #expect(state.squashRevision == 1)
    }

    // MARK: Signals, production and authors

    @Test func signalIndexPlacesAgentsOnTheirWorktree() throws {
        let tree = try #require(
            GitParsers.worktrees(Data("worktree /tmp/tree\0HEAD abc\0branch refs/heads/topic\0\0".utf8)).first)
        let agent = ProviderItem(
            id: "agent", provider: .orca, category: "", title: "", state: .running, worktreePath: "/tmp/tree",
            kind: .agent)
        let lost = ProviderItem(
            id: "lost", provider: .orca, category: "", title: "", state: .running, worktreePath: "/tmp/elsewhere",
            kind: .agent)
        let index = SignalIndex(
            reports: [ProviderReport(provider: .orca, items: [agent, lost], status: .connected)], worktrees: [tree])
        #expect(index.byCommit["abc"]?.map(\.id) == ["agent"])
        #expect(index.items.first?.branch == tree.branch)
        #expect(index.items.last?.commit == nil)
        #expect(SignalIndex().items.isEmpty)
    }

    @Test func anAgentInADetachedWorktreeIsLabelledDetachedHEAD() throws {
        let tree = try #require(GitParsers.worktrees(Data("worktree /tmp/tree\0HEAD abc\0detached\0\0".utf8)).first)
        let agent = ProviderItem(
            id: "agent", provider: .orca, category: "", title: "", state: .running, worktreePath: "/tmp/tree",
            kind: .agent)
        let index = SignalIndex(
            reports: [ProviderReport(provider: .orca, items: [agent], status: .connected)], worktrees: [tree])
        #expect(tree.branch == nil)
        #expect(index.items.first?.branch == "Detached HEAD")
    }

    @Test func productionBehindPrefersOriginsRemoteBranch() {
        let local = GitReference(name: "main", fullName: "refs/heads/main", commit: "l", kind: .branch)
        let fork = GitReference(name: "fork/main", fullName: "refs/remotes/fork/main", commit: "f", kind: .remote)
        let origin = GitReference(name: "origin/main", fullName: "refs/remotes/origin/main", commit: "o", kind: .remote)
        #expect(ProductionBehind.tip(of: "main", in: [local, fork, origin]) == origin)
        #expect(ProductionBehind.tip(of: "main", in: [local, fork]) == fork)
        #expect(ProductionBehind.tip(of: "main", in: [local]) == local)
        #expect(ProductionBehind.tip(of: "other", in: [local]) == nil)
    }

    @Test func commitAuthorsMatchByEmailElseName() {
        let author = CommitAuthor(commit("a", author: "Ann", email: "ann@example.com"))
        #expect(author.wrote(commit("b", author: "Other", email: "ANN@example.com")))
        #expect(!author.wrote(commit("c", author: "Ann", email: "else@example.com")))
        #expect(author.wrote(commit("d", author: "Ann")))
        #expect(!CommitAuthor(commit("e", author: "Bo")).wrote(commit("f", author: "Ann", email: "x@y")))
    }

    @Test func vercelAlertTrackerSeedsWithTheFirstSuccessfulRead() {
        var tracker = VercelAlertTracker()
        func signals(_ ids: [String], outcome: VercelSignals.Outcome = .value) -> VercelSignals {
            VercelSignals(
                alerts: ids.map { VercelSignals.Alert(id: $0) },
                reads: [.alerts: VercelSignals.Read(at: Date(), key: "", outcome: outcome)])
        }
        #expect(tracker.newAlerts(in: nil).isEmpty)
        #expect(tracker.newAlerts(in: VercelSignals()).isEmpty)
        #expect(tracker.newAlerts(in: signals(["a"], outcome: .failed)).isEmpty)
        #expect(tracker.newAlerts(in: signals(["a"])).isEmpty)
        #expect(tracker.newAlerts(in: signals(["a", "b"])).map(\.id) == ["b"])
        #expect(tracker.newAlerts(in: signals(["a", "b"])).isEmpty)
    }

    @Test func providerReportChanges() {
        let report = ProviderReport(provider: .github, items: [], status: .connected)
        #expect(report.differs(from: nil))
        #expect(!report.differs(from: report))
        var failed = report
        failed.diagnostic = "Offline"
        #expect(failed.differs(from: report))
        #expect(failed.statusDiffers(from: report))
        var moved = report
        moved.sourceID = "github:o/r"
        #expect(moved.differs(from: report))
        #expect(Set([ProviderKind.github, .vercel, .orca].map(\.displayName)).count == 3)
    }

    // MARK: Lists, sections and states

    @Test func changeListPutsConflictsFirst() {
        let changes = [
            FileChange(path: "staged", indexStatus: "M", worktreeStatus: " "),
            FileChange(path: "conflict", indexStatus: "U", worktreeStatus: "U"),
            FileChange(path: "unstaged", indexStatus: " ", worktreeStatus: "M"),
        ]
        #expect(ChangeList.files(changes, staged: true).map(\.path) == ["conflict", "staged"])
        #expect(ChangeList.files(changes, staged: false).map(\.path) == ["conflict", "unstaged"])
        #expect(snapshotWith(changes).conflictCount == 1)
    }

    private func snapshotWith(_ changes: [FileChange]) -> RepositorySnapshot {
        var value = snapshot()
        value.changes = changes
        return value
    }

    @Test func sectionsFromDeepLinks() {
        #expect(GitaUI.Section(link: "pull-requests") == .pullRequests)
        #expect(GitaUI.Section(link: "history") == .history)
        #expect(GitaUI.Section(link: "nope") == nil)
        for section in GitaUI.Section.allCases {
            #expect(!section.localizedTitle.isEmpty)
            #expect(!section.symbol.isEmpty)
        }
        #expect(GitaUI.Section.workspaceSections.first == .history)
    }

    @Test func statusTextsHaveLocalizedTitles() {
        let all: [RepositoryStatusText] = [
            .openRepository, .refreshing, .clean, .refreshFailed, .loadingHistory, .historyLoaded, .historyFailed,
            .searchFailed, .resolvingConflict, .rebasing,
        ]
        #expect(Set(all.map(\.localizedTitle)).count == all.count)
    }

    @Test func selectionSearchAndFocusStatesReset() {
        var selection = SelectionState()
        selection.commit = commit("a")
        selection.files = [FileChange(path: "x", indexStatus: "M", worktreeStatus: " ")]
        let revision = selection.filesRevision
        selection.clear()
        #expect(selection.commit == nil)
        #expect(selection.files.isEmpty)
        #expect(selection.filesRevision != revision)
        let generation = selection.generation
        selection.supersede()
        #expect(selection.generation == generation + 1)

        var search = HistorySearch()
        search.begin("x", field: .author)
        #expect(search.isActive && !search.isSearching)
        search.clear()
        #expect(!search.isActive)
        #expect(search.field == .author)
        let token = search.generation
        search.invalidate()
        #expect(search.generation == token + 1)

        var focus = BranchFocus()
        focus.reference = GitReference(name: "main", fullName: "refs/heads/main", commit: "a", kind: .branch)
        focus.commits = [commit("a")]
        let identity = focus.identity
        focus.discard()
        #expect(!focus.isActive)
        #expect(focus.commits.isEmpty)
        #expect(focus.identity != identity)
    }

    @Test func providerStateResetKeepsTheToldAlerts() {
        var state = ProviderState()
        state.reports = [ProviderReport(provider: .github, items: [], status: .connected)]
        state.vercelRequest = .contextAfterRead
        let epoch = state.details.epoch
        state.reset()
        #expect(state.reports.isEmpty)
        #expect(state.vercelRequest == .none)
        #expect(state.details.epoch == epoch + 1)
        #expect(state.report(.github) == nil)
    }
}
