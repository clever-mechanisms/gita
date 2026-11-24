import Foundation
import GitaCore

/// The laid-out history: graph links, folded merges, squash links and what the history list shows.
extension AppModel {
    /// The graph of the shown history rows (`displayedCommits` outside search and branch focus).
    var graph: [GraphRow] { graphState.layout.graph }
    /// Row lookup and parent rows for `snapshot.commits` (built with the graph, off the main thread).
    var historyIndex: HistoryIndex { graphState.layout.index }
    var squashLinks: [String: String] { graphState.squashLinks }
    var squashRevision: Int { graphState.squashRevision }
    var collapsesMerges: Bool { graphState.layout.isCollapsed }

    /// The graph links for `commits`: an author tab's own, else the parents plus squash links.
    func graphInput(_ commits: [GitCommit]) -> [GitCommit] {
        authorLens == nil
            ? HistoryGraphInput.make(commits, squashLinks: graphState.squashLinks)
            : HistoryGraphInput.lens(commits, links: graphState.lensLinks)
    }

    /// The tip `commit` squashed, when the graph draws that link.
    func squashTip(of commit: GitCommit) -> String? {
        guard let tip = graphState.squashLinks[commit.id], let row = historyIndex.rowByID[commit.id],
            let tipRow = historyIndex.rowByID[tip], tipRow > row
        else { return nil }
        return tip
    }

    /// Finds squash merges again when the references move (read-only, off the main thread) and lays the graph out
    /// again when they change. Off in an author tab and while the setting is off.
    func updateSquashLinks() {
        guard let service, let snapshot, authorLens == nil else { return }
        guard Preference.squashMergesAsMerges.bool(defaults) else {
            graphState.cancelSquashSearch()
            if !graphState.squashLinks.isEmpty {
                graphState.squashLinks = [:]
                relayoutHistory()
            }
            return
        }
        let key = HistoryGraphState.squashKey(snapshot)
        guard key != graphState.squashSearch.key else { return }
        graphState.squashSearch.cancel()
        let current = generation
        graphState.squashSearch = .searching(
            key: key,
            Task { [weak self] in
                let links = try? await service.squashMerges()
                guard let self, !Task.isCancelled, current == self.generation else { return }
                // A failed search keeps the links shown and forgets its key: the next update searches again.
                guard let links else {
                    self.graphState.squashSearch = .none
                    return
                }
                self.graphState.squashSearch = .found(key: key)
                guard links != self.graphState.squashLinks else { return }
                self.graphState.squashLinks = links
                self.relayoutHistory()
            })
    }

    /// Lays the loaded history out again with the current graph links and folding (the commits are unchanged).
    /// `revealing`: expands the collapsed merges hiding that commit (inner ones too) first; `then` runs once laid out.
    /// Only the latest relayout lands (`HistoryRelayout`): quickly expanding then folding a merge ends folded.
    func relayoutHistory(revealing target: String? = nil, then: (@MainActor () -> Void)? = nil) {
        guard let snapshot, authorLens == nil else {
            then?()
            return
        }
        let commits = snapshot.commits
        let input = HistoryLayoutInput(
            commits: commits, graphCommits: graphInput(commits), linked: !graphState.squashLinks.isEmpty,
            index: historyIndex.count == commits.count ? historyIndex : nil, folding: folding(head: snapshot.head))
        let current = generation
        let id = UUID()
        let task = Task { [weak self] in
            let (layout, folding) = await Task.detached(priority: .userInitiated) {
                input.build(revealing: target)
            }.value
            guard let self, case .running(_, _, let waiting) = self.graphState.endRelayout(id),
                current == self.generation, self.snapshot?.commits == commits
            else { return }
            if let folding { self.graphState.expandedMerges = folding.expanded }
            // Bumped with the new graph in place: the history list redraws with it, not before it.
            self.graphState.layout = layout
            self.graphState.squashRevision += 1
            self.emit(.history)
            self.fillCollapsedHistory()
            for callback in waiting { callback() }
        }
        graphState.startRelayout(id, task, then: then)
    }

    /// What the history folds with Settings › Git › Collapse merged commits on (never in an author tab): every
    /// merge but the expanded ones; HEAD always stays shown.
    func folding(head: String?) -> HistoryLayout.Folding? {
        guard Preference.collapsesMergedCommits.bool(defaults), authorLens == nil else { return nil }
        return HistoryLayout.Folding(expanded: graphState.expandedMerges, pinned: Set([head].compactMap { $0 }))
    }

    /// The shown merge that hides `id` in a collapsed history.
    func collapsedMerge(hiding id: String) -> String? {
        let layout = graphState.layout
        guard layout.isCollapsed, let row = historyIndex.rowByID[id], let commits = snapshot?.commits,
            let merge = layout.hidingRow(of: row), commits.indices.contains(merge)
        else { return nil }
        return commits[merge].id
    }

    /// A collapsed history shows few rows per page (a page of 500 commits can fold to a handful of merges): read
    /// further pages until the list has some length, up to 20 000 loaded commits; scrolling loads more as usual.
    func fillCollapsedHistory() {
        guard graphState.layout.isCollapsed, case let shown = graphState.layout.shown,
            shown.count < HistoryLayoutInput.collapsedMinimumRows,
            let snapshot, snapshot.hasMoreHistory, snapshot.commits.count < HistoryLayoutInput.collapsedMaximumCommits,
            !isLoading, authorLens == nil
        else { return }
        loadMore()
    }

    func isMergeExpanded(_ id: String) -> Bool { graphState.expandedMerges.contains(id) }
    /// Shows a collapsed merge's commits in the history (and any merges folding `revealing` inside it), then `then`.
    func expandMerge(_ id: String, revealing target: String? = nil, then: (@MainActor () -> Void)? = nil) {
        graphState.expandedMerges.insert(id)
        relayoutHistory(revealing: target, then: then)
    }
    /// Folds an expanded merge again, with the merges opened inside it.
    func collapseMerge(_ id: String) {
        guard graphState.expandedMerges.remove(id) != nil else { return }
        if let index = historyIndex.rowByID[id] {
            let inside = Set(historyIndex.mergedRows(of: index, limit: .max).rows)
            graphState.expandedMerges = graphState.expandedMerges.filter {
                historyIndex.rowByID[$0].map { !inside.contains($0) } ?? false
            }
        }
        relayoutHistory()
    }
    /// Shows `id` in the history: expands the collapsed merges hiding it, then `then` (at once when it is shown).
    func reveal(_ id: String, then: @escaping @MainActor () -> Void) {
        guard let merge = collapsedMerge(hiding: id) else {
            then()
            return
        }
        expandMerge(merge, revealing: id, then: then)
    }

    // MARK: What the history list shows: search results, a branch focus or the (folded) history

    /// What the history list shows. A search and a branch focus end each other (`searchHistory`, `focusHistory`);
    /// `HistoryMode` puts the search first should both be set.
    var historyMode: HistoryMode {
        HistoryMode(
            searchQuery: search.query, field: search.field,
            focusedIdentity: focus.isActive ? focus.identity : nil,
            authorFilterIdentity: graphState.inlineAuthor.isActive ? graphState.inlineAuthor.identity : nil)
    }

    /// The full loaded history merge lists walk: the shown rows leave a collapsed merge's commits out.
    var mergeHistory: (index: HistoryIndex, commits: [GitCommit]) {
        if graphState.inlineAuthor.isActive {
            return (graphState.inlineAuthor.index, graphState.inlineAuthor.commits)
        }
        return focus.isActive ? (focus.index, focus.commits) : (historyIndex, snapshot?.commits ?? [])
    }
    var displayedCommits: [GitCommit] {
        switch historyMode {
        case .search: search.results
        case .authorFilter: graphState.inlineAuthor.commits
        case .focused: focus.commits
        case .all: graphState.layout.isCollapsed ? graphState.layout.shown : snapshot?.commits ?? []
        }
    }
    var displayedHistoryHasMore: Bool {
        switch historyMode {
        case .search: search.hasMore
        case .authorFilter: graphState.inlineAuthor.hasMore
        case .focused: focus.hasMore
        case .all: snapshot?.hasMoreHistory == true
        }
    }
    /// Nil while searching: results are not an ancestry walk.
    var displayedHistoryIndex: HistoryIndex? {
        switch historyMode {
        case .search: nil
        case .authorFilter: graphState.inlineAuthor.index
        case .focused: focus.index
        case .all: graphState.layout.isCollapsed ? graphState.layout.shownIndex : historyIndex
        }
    }
    var displayedHistoryIsLoading: Bool {
        switch historyMode {
        case .search: search.isSearching
        case .authorFilter: graphState.inlineAuthor.isLoading
        case .focused: focus.isLoading
        case .all: isLoading
        }
    }
    /// The shown list's last page read failed: it offers Retry. Each list keeps its own failure, so one that ends
    /// takes its failure with it.
    var historyPageFailed: Bool {
        switch historyMode {
        case .search: search.read.hasFailed
        case .authorFilter: graphState.inlineAuthor.read.hasFailed
        case .focused: focus.read.hasFailed
        case .all: allHistoryPageFailed
        }
    }

    // MARK: §6b History Selection, Working Changes & Two-Commit Compare

    var historySelection: HistorySelection { graphState.historySelection }
    var isReviewingWorkingChanges: Bool { graphState.isReviewingWorkingChanges }
    var compareState: CompareState? { graphState.compare }

    func selectHistory(_ next: HistorySelection) {
        graphState.isReviewingWorkingChanges = false
        switch next {
        case .none:
            graphState.historySelection = .none
            clearCompareState()
            deselectCommit()
        case .commit(let id):
            graphState.historySelection = .commit(id)
            clearCompareState()
            if let commit = displayedCommits.first(where: { $0.id == id })
                ?? snapshot?.commits.first(where: { $0.id == id })
            {
                select(commit)
            }
        case .pair(let base, let head):
            graphState.historySelection = .pair(base, head)
            selection.task?.cancel()
            selection.clear()
            loadCompare(base: base, head: head)
            emit(.selection)
        case .many(let ids):
            graphState.historySelection = .many(ids)
            clearCompareState()
            selection.task?.cancel()
            selection.clear()
            emit(.selection)
            emit(.diff)
        }
    }

    func selectWorkingChanges() {
        graphState.historySelection = .none
        clearCompareState()
        graphState.isReviewingWorkingChanges = true
        selection.task?.cancel()
        selection.clear()
        showChanges()
        emit(.selection)
    }

    func swapCompareCommits() {
        let next = graphState.historySelection.swapped()
        guard case .pair = next else { return }
        selectHistory(next)
    }

    func selectCompareFile(_ file: FileChange) {
        guard let service, let current = graphState.compare else { return }
        graphState.compareGeneration += 1
        let token = graphState.compareGeneration
        let base = current.base
        let head = current.head
        graphState.compare?.selectedFile = file
        graphState.compare?.diff = ""
        graphState.compare?.isLoadingDiff = true
        emit(.selection)
        graphState.compareTask?.cancel()
        graphState.compareTask = Task { [weak self] in
            do {
                let text = try await service.compareDiff(base: base, head: head, path: file.path)
                guard let self, !Task.isCancelled, self.graphState.compareGeneration == token else { return }
                self.graphState.compare?.diff = text
                self.graphState.compare?.isLoadingDiff = false
                self.emit(.selection)
            } catch {
                guard let self, !Task.isCancelled, self.graphState.compareGeneration == token else { return }
                self.graphState.compare?.diff = error.localizedDescription
                self.graphState.compare?.isLoadingDiff = false
                self.emit(.selection)
            }
        }
    }

    private func clearCompareState() {
        graphState.compareGeneration += 1
        graphState.compareTask?.cancel()
        graphState.compareTask = nil
        graphState.compare = nil
    }

    private func loadCompare(base: String, head: String) {
        guard let service else { return }
        graphState.compareGeneration += 1
        let token = graphState.compareGeneration
        graphState.compareTask?.cancel()
        graphState.compare = CompareState(base: base, head: head, isLoadingFiles: true, isLoadingDiff: true)
        graphState.compareTask = Task { [weak self] in
            do {
                async let files = service.compareFiles(base: base, head: head)
                async let distance = service.commitDistance(from: base, to: head)
                let loadedFiles = try await files
                let loadedDistance = await distance
                guard let self, !Task.isCancelled, self.graphState.compareGeneration == token else { return }
                self.graphState.compare?.files = loadedFiles
                self.graphState.compare?.distance = loadedDistance
                self.graphState.compare?.isLoadingFiles = false
                if let first = loadedFiles.first {
                    self.selectCompareFile(first)
                } else {
                    self.graphState.compare?.isLoadingDiff = false
                    self.emit(.selection)
                }
            } catch {
                guard let self, !Task.isCancelled, self.graphState.compareGeneration == token else { return }
                self.graphState.compare?.isLoadingFiles = false
                self.graphState.compare?.isLoadingDiff = false
                self.graphState.compare?.diff = error.localizedDescription
                self.log(String(localized: "Compare failed"), error.localizedDescription, failed: true)
                self.emit(.selection)
            }
        }
    }

    // MARK: Zoom and details (View menu, Settings › Git)

    var historyZoomPercent: Int { HistoryZoom.clamped(Preference.historyZoomPercent.int(defaults)) }
    var showsHistoryDetails: Bool { Preference.showsHistoryDetails.bool(defaults) }
    var showsMergeLabel: Bool { Preference.showsMergeLabel.bool(defaults) }
    func toggleHistoryDetails() {
        Preference.showsHistoryDetails.set(!showsHistoryDetails, defaults)
        emit(.historyAppearance)
    }
}
