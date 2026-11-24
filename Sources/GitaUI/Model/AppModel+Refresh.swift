import Foundation
import GitaCore

/// Reading the repository again: the snapshot, its history layout and what the window keeps showing.
extension AppModel {
    func refresh() {
        // Debounces and the periodic timer can fire after a mutation starts.
        // Its completion already refreshes once; do not repeatedly read a replay in flight.
        guard let service, !isLoading, !isMutating else {
            dirty = true
            pendingRefresh = true
            return
        }
        pendingRefresh = false
        let current = generation
        let revision = filesystemRevision
        let scope = branchFilters.scope
        let staging = amendStaging
        // The task runs once this call returns: everything below sees the read in flight.
        let task = Task { [weak self] in
            do {
                guard
                    let read = try await self?.readSnapshot(
                        service, scope: scope, amendStaging: staging, generation: current),
                    let built = await self?.layout(for: read.snapshot),
                    let self, !Task.isCancelled, self.generation == current
                else { return }
                self.apply(read.snapshot, amendStaging: read.amendStaging, layout: built, revision: revision)
                self.maintainGitCaches()
            } catch {
                guard let self, !Task.isCancelled, self.generation == current else { return }
                self.endFailedRead {
                    self.dropPreview()
                    self.setReadStatus(.refreshFailed)
                    self.log(String(localized: "Refresh failed"), error.localizedDescription, failed: true)
                }
            }
        }
        read = .refreshing(task)
        setReadStatus(.refreshing)
        emit(.status)
        checkCommitGraphSoon()
    }

    /// Ends a read that failed: idle before `report` and the status change tell observers (a tab that never opened
    /// is told apart by it), then the refresh asked for meanwhile starts.
    func endFailedRead(_ report: () -> Void) {
        read = .idle
        report()
        emit(.status)
        if pendingRefresh { refresh() }
    }

    /// The snapshot with the history to show: an author tab's commits (read again only when the references or
    /// ancestry moved), or the pages already loaded while the same ordered references and HEAD stay valid.
    private func readSnapshot(
        _ service: GitService, scope: HistoryScope, amendStaging: AmendStaging, generation current: Int
    ) async throws
        -> (snapshot: RepositorySnapshot, amendStaging: AmendStaging)?
    {
        // A repository's first read shows its history as soon as it is walked, before the working-tree status.
        var early: (@Sendable (RepositorySnapshot) async -> Void)?
        if snapshot == nil, authorLens == nil {
            early = { @Sendable [weak self] preview in await self?.showPreview(preview, generation: current) }
        }
        var next = try await service.snapshot(limit: HistoryPage.size, scope: scope, early: early)
        let old = snapshot
        if let lens = authorLens {
            if let old, old.historyIdentity != nil, old.historyIdentity == next.historyIdentity {
                next.commits = old.commits
                next.hasMoreHistory = old.hasMoreHistory
            } else {
                let history = try await service.authorHistory(
                    name: lens.name, email: lens.email, scope: next.historyScope,
                    limit: max(HistoryPage.size, old?.commits.count ?? 0))
                guard !Task.isCancelled, generation == current else { return nil }
                next.commits = history.commits
                next.hasMoreHistory = history.hasMore
                graphState.lensLinks = history.graphParents
            }
        } else if let old, HistoryPage.keepsLoadedPages(old, next) {
            next.commits = old.commits
            next.hasMoreHistory = old.hasMoreHistory
        }
        let nextAmendStaging: AmendStaging =
            if case .armed(let base, let head, _) = amendStaging,
                next.head == head, next.operation == nil, next.conflictCount == 0
            {
                .armed(base: base, head: head, files: try await service.stagedChanges(against: base))
            } else {
                .off
            }
        return (next, nextAmendStaging)
    }

    /// The history of a repository being read for the first time, while its status is still being read. The status
    /// line keeps saying it is refreshing; the full snapshot replaces this one as the repository's first.
    private func showPreview(_ preview: RepositorySnapshot, generation current: Int) async {
        guard generation == current, snapshot == nil, read.isRefreshing else { return }
        let built = await layout(for: preview)
        guard generation == current, snapshot == nil, read.isRefreshing else { return }
        snapshot = preview
        root = preview.root
        graphState.layout = built
        emit(.repository)
    }

    /// The first read failed after its history was shown: the preview has no working-tree status, so it does not
    /// stay as the repository's snapshot (it would show a clean working tree).
    func dropPreview() {
        guard snapshot?.isPreview == true else { return }
        snapshot = nil
        graphState.layout = .empty
        emit(.repository)
    }

    /// Same commits (the usual working-tree refresh): the graph and index stay instead of being rebuilt.
    private func layout(for next: RepositorySnapshot) async -> HistoryLayout {
        let commits = next.commits
        let folding = folding(head: next.head)
        if let old = snapshot, old.commits.count == commits.count, old.commits == commits,
            graphState.layout.describes(commits.count, folding: folding)
        {
            return graphState.layout
        }
        let input = HistoryLayoutInput(
            commits: commits, graphCommits: graphInput(commits), linked: !graphState.squashLinks.isEmpty, index: nil,
            folding: folding)
        return await Task.detached(priority: .userInitiated) { input.build() }.value
    }

    private func finishRefresh(_ next: RepositorySnapshot, revision: Int) {
        read = .idle
        if next.changes.isEmpty {
            setReadStatus(.clean)
        } else {
            setReadStatus(String(localized: "\(next.changes.count) changed files"))
        }
        dirty = filesystemRevision != revision || pendingRefresh
    }

    /// Read again after a refresh when one was asked for meanwhile (a mutation ended, say), or the working tree moved
    /// and the repository is still worth reading now.
    private func needsAnotherRefresh(_ next: RepositorySnapshot) -> Bool {
        pendingRefresh || (dirty && (isObserved || !walksBranchFilters(next)))
    }

    private func apply(
        _ next: RepositorySnapshot, amendStaging nextAmendStaging: AmendStaging, layout built: HistoryLayout,
        revision: Int
    ) {
        let previous = snapshot
        let before = refreshBefore()
        let previousFile = selection.file?.path
        guard draftController.restore(for: next) else {
            endFailedRead { setReadStatus(.refreshFailed) }
            return
        }
        // A preview is not a read of the repository: what follows is its first snapshot.
        let first = previous?.isPreview ?? true
        if let previous, previous == next, amendStaging == nextAmendStaging {
            // Nothing Git reports changed: no list rebuild, no reload, no diff reload.
            finishRefresh(next, revision: revision)
            emit(.status)
            if pendingRefresh || (dirty && isObserved) { refresh() }
            return
        }
        let remoteChanged = !first && previous?.remoteURL != next.remoteURL
        applyAmendStaging(nextAmendStaging)
        snapshot = next
        root = next.root
        graphState.layout = built
        updateProductionBehind()
        updateSquashLinks()
        if remoteChanged { forgetHostedRepository() }
        rebuildSignalIndex()
        finishRefresh(next, revision: revision)
        syncRemoteMonitor(with: next)
        if first { didOpen(next) }
        emit(.repository)
        apply(RefreshPlan(before: before, next: next), previousFile: previousFile)
        fillCollapsedHistory()
        if first || remoteChanged { refreshProviders() }
        if needsAnotherRefresh(next) { refresh() }
    }

    private func refreshBefore() -> RefreshPlan.Before {
        RefreshPlan.Before(
            section: section, operationIdentity: snapshot?.operation?.identity,
            historyIdentity: snapshot?.historyIdentity, ancestryIdentity: snapshot?.ancestryIdentity,
            commit: selection.commit, stash: selection.stash, hasCommitDetails: selection.details != nil,
            isTreeReview: isTreeReview, focusedFirst: focus.commits.first, isFocused: focus.isActive,
            isSearching: search.isActive)
    }

    /// The first snapshot of a newly opened repository: its branch filters, the recent list and the watcher.
    private func didOpen(_ next: RepositorySnapshot) {
        // The repository's branch filters are known once its common Git directory is: walk them now.
        branchFilters = BranchFilters.load(next.commonGitDirectory, from: defaults)
        if !walksBranchFilters(next) { dirty = true }
        observeBranchFilters(next.commonGitDirectory)
        defaults.set(RecentRepositories.inserting(next.root.path, into: recent), forKey: recentKey)
        // Gitignored build output (`.build/`, `node_modules/`) is filtered off the main thread and never refreshes.
        replaceWatcher(
            RepositoryWatcher(
                paths: Array(Set([next.root.path, next.gitDirectory.path, next.commonGitDirectory.path])),
                ignoredPaths: [next.commonGitDirectory.appendingPathComponent("objects").path],
                gitEvents: GitDirectoryEvents(
                    gitDirectory: next.gitDirectory, commonDirectory: next.commonGitDirectory),
                filter: WorktreeEventFilter(root: next.root)
            ) { [weak self] in self?.repositoryChanged() })
        log(String(localized: "Opened repository"), next.root.lastPathComponent)
    }

    /// The same working copy now refers to a different hosted repository: its old PR and check data must go.
    private func forgetHostedRepository() {
        providers.full.cancel()
        providers.cancelFastReads()
        providers.reports.removeAll { $0.provider == .github }
        providers.details.remove(provider: .github)
        notificationTracker.reset(provider: .github)
    }

    private func apply(_ plan: RefreshPlan, previousFile: String?) {
        switch plan.reselection {
        case .enterChanges:
            staged = false
            section = .changes
        case .refreshChanges(let unstage):
            if unstage { staged = false }
            showChanges(preferredPath: previousFile, refreshing: true)
        case .stash(let stash): selectStash(stash)
        case .keep(let commit, let notify):
            selection.commit = commit
            if notify { emit(.selection) }
        case .select(let commit): select(commit, preferredPath: previousFile, base: selection.base)
        case .nothing: break
        }
        if plan.restartsSearch { searchHistory(search.query, field: search.field) }
        switch plan.focus {
        case .refocus: if let reference = focus.reference { focusHistory(on: reference) }
        case .discard:
            focus.discard()
            focus.allHistorySelection = nil
            emit(.history)
        case .none: break
        }
    }

    // MARK: Background Remote Awareness

    var remoteCheckState: RemoteCheckState { RemoteMonitor.shared.state(for: root) }
    var remoteDelta: RemoteDelta? { remoteCheckState.last }
    var remoteCheckStatusSummary: String { RemoteMonitor.shared.statusSummary(for: root) }

    func checkRemotesNow() { RemoteMonitor.shared.checkNow(for: root) }

    func syncRemoteMonitor(with snapshot: RepositorySnapshot) {
        guard let service else { return }
        RemoteMonitor.shared.register(
            model: self, root: snapshot.root, service: service, snapshot: snapshot, defaults: defaults)
    }

    func remoteCheckStateChanged(_ next: RemoteCheckState, previous: RemoteCheckState) {
        if next.last != previous.last || next.isBusy != previous.isBusy
            || next.statusSummary() != previous.statusSummary()
        {
            emit(.providers)
        }
    }

    func remoteAutoFetchCompleted() {
        refresh()
    }
}
