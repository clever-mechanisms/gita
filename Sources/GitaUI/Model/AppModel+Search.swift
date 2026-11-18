import Foundation
import GitaCore

/// Searching the history and focusing it on one branch.
extension AppModel {
    private static let searchDebounce = Duration.milliseconds(250)

    var searchQuery: String { search.query }
    var searchField: HistorySearchField { search.field }
    var isSearchingHistory: Bool { search.isActive }
    var focusedReference: GitReference? { focus.reference }
    var focusedGraph: [GraphRow] { focus.graph }
    var focusedHistoryIdentity: UUID { focus.identity }

    func searchHistory(_ query: String, field: HistorySearchField) {
        if !query.isEmpty {
            focus.discard()
            focus.allHistorySelection = nil
        }
        search.begin(query, field: field)
        allHistoryPageFailed = false
        if search.isActive { readSearchPage(debounce: true) }
        emit(.history)
    }

    func loadMoreSearch() {
        guard search.hasMore, !search.isSearching else { return }
        readSearchPage(debounce: false)
        emit(.history)
    }

    /// Reads the next page of results (`search.read` holds it while it runs); without a repository nothing is read.
    private func readSearchPage(debounce: Bool) {
        guard let service else {
            search.read = .idle
            return
        }
        let token = search.generation
        let repository = generation
        let revision = filesystemRevision
        let query = search.query
        let field = search.field
        let offset = search.results.count
        search.read = .reading(
            Task { [weak self] in
                do {
                    if debounce { try await Task.sleep(for: Self.searchDebounce) }
                    let page = try await service.searchHistory(
                        query: query, field: field, limit: HistoryPage.request, skip: offset)
                    guard let self, !Task.isCancelled, self.search.generation == token, self.generation == repository
                    else { return }
                    guard self.filesystemRevision == revision else {
                        self.searchHistory(query, field: field)
                        return
                    }
                    self.search.results += page.prefix(HistoryPage.size)
                    self.search.hasMore = HistoryPage.hasMore(page)
                    self.search.read = .idle
                    self.emit(.history)
                } catch {
                    guard let self, !Task.isCancelled, self.search.generation == token, self.generation == repository
                    else { return }
                    self.search.read = .failed
                    self.log(String(localized: "Search failed"), error.localizedDescription, failed: true)
                    self.setReadStatus(.searchFailed)
                    self.emit(.history)
                }
            })
    }

    // MARK: Branch focus

    func focusHistory(on reference: GitReference) {
        guard service != nil else { return }
        if !focus.isActive { focus.allHistorySelection = selection.commit }
        focus.discard()
        search.clear()
        focus.reference = reference
        focus.hasMore = true
        selection.task?.cancel()
        selection.clear()
        emit(.selection)
        emit(.diff)
        loadMoreFocusedHistory()
    }

    func showAllHistory(selecting commit: GitCommit? = nil) {
        let target = commit ?? focus.allHistorySelection ?? snapshot?.commits.first
        focus.discard()
        focus.allHistorySelection = nil
        search.clear()
        allHistoryPageFailed = false
        setReadStatus(.historyLoaded)
        emit(.history)
        if let target { select(snapshot?.commits.first(where: { $0.id == target.id }) ?? target) }
    }

    func loadMoreFocusedHistory() {
        guard let service, let reference = focus.reference, focus.hasMore, !focus.isLoading else { return }
        let token = focus.identity
        let repository = generation
        let selectionToken = selection.generation
        let existing = focus.commits
        let task = Task { [weak self] in
            do {
                let page = try await service.history(
                    from: reference.commit, limit: HistoryPage.request, skip: existing.count)
                guard let self, !Task.isCancelled, self.generation == repository, self.focus.identity == token
                else { return }
                let known = Set(existing.map(\.id))
                let combined = existing + page.prefix(HistoryPage.size).filter { !known.contains($0.id) }
                let (layout, index) = await Task.detached(priority: .userInitiated) {
                    (GraphLayout.build(commits: combined), HistoryIndex(commits: combined))
                }.value
                guard !Task.isCancelled, self.generation == repository, self.focus.identity == token else { return }
                self.focus.commits = combined
                self.focus.graph = layout
                self.focus.index = index
                self.focus.hasMore = HistoryPage.hasMore(page)
                self.finishFocusedRead(.historyLoaded)
                if existing.isEmpty, self.section == .history, self.selection.generation == selectionToken,
                    let first = combined.first
                {
                    self.select(first)
                }
            } catch {
                guard let self, !Task.isCancelled, self.generation == repository, self.focus.identity == token
                else { return }
                self.log(String(localized: "History failed"), error.localizedDescription, failed: true)
                self.finishFocusedRead(.historyFailed)
            }
        }
        focus.read = .reading(task)
        allHistoryPageFailed = false
        setReadStatus(.loadingHistory)
        emit(.history)
    }

    private func finishFocusedRead(_ status: RepositoryStatusText) {
        focus.read = status == .historyFailed ? .failed : .idle
        setReadStatus(status)
        emit(.history)
    }
}
