import Foundation
import GitaCore

/// Reading further pages of the history as the list scrolls.
extension AppModel {
    /// When a page read started: a newer repository or a working-tree change makes it stale.
    private struct PageRead {
        var generation: Int
        var revision: Int
    }

    func loadMore() {
        guard let service, let existing = snapshot, !isLoading, existing.hasMoreHistory else { return }
        allHistoryPageFailed = false
        let started = PageRead(generation: generation, revision: filesystemRevision)
        // The task runs once this call returns: everything below sees the read in flight.
        let task = Task { [weak self] in
            do {
                if let lens = self?.authorLens {
                    try await self?.loadAuthorPage(lens, existing: existing, service: service, started: started)
                } else {
                    try await self?.loadPage(existing: existing, service: service, started: started)
                }
            } catch {
                guard let self, started.generation == self.generation, !Task.isCancelled else { return }
                self.endFailedRead {
                    self.allHistoryPageFailed = true
                    self.setReadStatus(.historyFailed)
                    self.log(String(localized: "History failed"), error.localizedDescription, failed: true)
                }
            }
        }
        read = .loadingPage(task)
        setReadStatus(.loadingHistory)
        emit(.status)
        checkCommitGraphSoon()
    }

    /// An author tab reads the longer list again: the links of the rows already shown can reach the new ones.
    private func loadAuthorPage(
        _ lens: CommitAuthor, existing: RepositorySnapshot, service: GitService, started: PageRead
    ) async throws {
        let history = try await service.authorHistory(
            name: lens.name, email: lens.email, scope: existing.historyScope,
            limit: existing.commits.count + HistoryPage.further)
        guard !Task.isCancelled, started.generation == generation else { return }
        graphState.lensLinks = history.graphParents
        let input = HistoryLayoutInput(
            commits: history.commits, graphCommits: graphInput(history.commits), linked: true, index: nil,
            folding: nil)
        let built = await Task.detached(priority: .userInitiated) { input.build() }.value
        guard started.generation == generation, !Task.isCancelled else { return }
        var combined = existing
        combined.commits = history.commits
        combined.hasMoreHistory = history.hasMore
        install(combined, layout: built, started: started)
    }

    private func loadPage(existing: RepositorySnapshot, service: GitService, started: PageRead) async throws {
        let page = try await service.history(
            limit: HistoryPage.further + 1, skip: existing.commits.count, scope: existing.historyScope)
        guard !Task.isCancelled, started.generation == generation else { return }
        guard started.revision == filesystemRevision else {
            read = .idle
            refresh()
            return
        }
        let known =
            historyIndex.count == existing.commits.count ? historyIndex.rowByID : HistoryPage.rows(existing.commits)
        let added = HistoryPage.added(page, known: known, size: HistoryPage.further)
        var combined = existing
        combined.commits += added
        combined.hasMoreHistory = HistoryPage.hasMore(page, size: HistoryPage.further)
        let built = await layout(appending: added, to: existing, all: combined.commits, known: known)
        guard started.generation == generation, !Task.isCancelled else { return }
        if install(combined, layout: built, started: started) { fillCollapsedHistory() }
        maintainGitCaches()
    }

    /// Continues the existing layout only if it still describes exactly the existing rows, and no squash commit
    /// already laid out links to a branch tip on the new page. A collapsed history is folded again as a whole: the
    /// new rows can be hidden by merges already shown.
    private func layout(
        appending added: [GitCommit], to existing: RepositorySnapshot, all commits: [GitCommit], known: [String: Int]
    ) async -> HistoryLayout {
        let graphCommits = graphInput(commits)
        let addedIDs = Set(added.map(\.id))
        let reachesBack = graphState.squashLinks.contains { known[$0.key] != nil && addedIDs.contains($0.value) }
        let folding = folding(head: existing.head)
        let input = HistoryLayoutInput(
            commits: commits, graphCommits: graphCommits, linked: !graphState.squashLinks.isEmpty, index: nil,
            folding: folding)
        let continuing =
            folding == nil && !graphState.layout.isCollapsed && graph.count == existing.commits.count && !reachesBack
            ? graphState.layout : nil
        let tail = Array(graphCommits.suffix(added.count))
        return await Task.detached(priority: .userInitiated) {
            continuing?.appending(tail, all: commits) ?? input.build()
        }.value
    }

    /// Older commits appended: only the history list changed (no sidebar, tabs, status item or page rebuild).
    /// A working-tree change meanwhile reads the repository again instead; false then.
    @discardableResult
    private func install(_ combined: RepositorySnapshot, layout built: HistoryLayout, started: PageRead) -> Bool {
        read = .idle
        guard started.revision == filesystemRevision, !pendingRefresh else {
            refresh()
            return false
        }
        snapshot = combined
        graphState.layout = built
        setReadStatus(.historyLoaded)
        emit(.history)
        emit(.status)
        return true
    }
}
