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
            searchQuery: search.query, field: search.field, focusedIdentity: focus.isActive ? focus.identity : nil)
    }

    /// The full loaded history merge lists walk: the shown rows leave a collapsed merge's commits out.
    var mergeHistory: (index: HistoryIndex, commits: [GitCommit]) {
        focus.isActive ? (focus.index, focus.commits) : (historyIndex, snapshot?.commits ?? [])
    }
    var displayedCommits: [GitCommit] {
        switch historyMode {
        case .search: search.results
        case .focused: focus.commits
        case .all: graphState.layout.isCollapsed ? graphState.layout.shown : snapshot?.commits ?? []
        }
    }
    var displayedHistoryHasMore: Bool {
        switch historyMode {
        case .search: search.hasMore
        case .focused: focus.hasMore
        case .all: snapshot?.hasMoreHistory == true
        }
    }
    /// Nil while searching: results are not an ancestry walk.
    var displayedHistoryIndex: HistoryIndex? {
        switch historyMode {
        case .search: nil
        case .focused: focus.index
        case .all: graphState.layout.isCollapsed ? graphState.layout.shownIndex : historyIndex
        }
    }
    var displayedHistoryIsLoading: Bool {
        switch historyMode {
        case .search: search.isSearching
        case .focused: focus.isLoading
        case .all: isLoading
        }
    }
    /// The shown list's last page read failed: it offers Retry. Each list keeps its own failure, so one that ends
    /// takes its failure with it.
    var historyPageFailed: Bool {
        switch historyMode {
        case .search: search.read.hasFailed
        case .focused: focus.read.hasFailed
        case .all: allHistoryPageFailed
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
