import AppKit
import GitaCore

/// The history list: which commits it shows, its header, zoom and paging, search, and moving to a commit.
extension RepositoryViewController {
    var historyMode: HistoryMode {
        HistoryMode(
            searchQuery: model.searchQuery, field: model.searchField,
            focusedIdentity: model.focusedReference != nil ? model.focusedHistoryIdentity : nil)
    }

    /// The list the model now shows: kept (a working-tree refresh), a page appended, or reloaded.
    func filterHistory() {
        let mode = historyMode
        let clip = historyTable.scroll.contentView
        let origin = scrollMemory.origin(
            for: mode, current: clip.bounds.origin, rowHeight: historyTable.table.rowHeight)
        historyControls.search.stringValue = model.searchQuery
        updateHistoryScope()
        let next = nextHistoryList(mode)
        // A squash commit already shown can link to a tip on the new page: its rows were laid out again.
        let graphCanChange = model.focusedReference == nil && (!model.squashLinks.isEmpty || model.collapsesMerges)
        let plan = historyTable.plan(next, graphCanChange: graphCanChange)
        historyTable.highlightedAuthor = model.highlightedAuthor
        switch plan {
        case .unchanged:
            historyTable.select(model.selectedCommit?.id)
        case .append:
            // Merge counts cut short by the old end of the list may now be longer: recount those.
            let incomplete = mergedCache.dropIncomplete()
            historyTable.apply(.append, next, index: model.displayedHistoryIndex, origin: origin)
            historyTable.reloadSubjects(historyTable.visibleRows(of: incomplete))
        case .reload:
            let ancestry = (model.snapshot?.ancestryIdentity ?? "") + "|squash:\(model.squashRevision)"
            mergedCache.listReloaded(ancestry: ancestry)
            mergedPopover.close()
            historyTable.apply(.reload, next, index: model.displayedHistoryIndex, origin: origin)
            historyTable.select(model.selectedCommit?.id)
        }
    }

    private func nextHistoryList(_ mode: HistoryMode) -> HistoryListState {
        let commits = model.displayedCommits
        let remoteNames = Set((model.snapshot?.references ?? []).filter { $0.kind == .remote }.map(\.name))
        // Search omits ancestors; connecting edges would imply false ancestry.
        let graphs =
            mode.isSearch
            ? commits.map { _ in GraphRow(lane: 0, color: 0, incoming: [], outgoing: []) }
            : model.focusedReference != nil ? model.focusedGraph : model.graph
        return HistoryListState(
            signature: .init(
                mode: mode, head: model.snapshot?.head, remoteNames: remoteNames, squashRevision: model.squashRevision),
            commits: commits, graphs: graphs)
    }

    /// The header names what the list shows; its tooltip names what the graph leaves out.
    func updateHistoryScope() {
        let scope = HistoryScopePresenter(
            .init(
                focused: model.section == .history ? model.focusedReference : nil, filters: model.branchFilters,
                references: model.snapshot?.references ?? [], isSearching: model.isSearchingHistory,
                searchField: model.searchField, searchQuery: model.searchQuery, authorLens: model.authorLens?.name,
                branch: model.snapshot?.localizedBranch))
        historyTable.setTitle(scope.title, toolTip: scope.toolTip)
        historyControls.show(scope)
    }

    /// The zoom, highlighted author and merge labels: every row is drawn again.
    func applyHistoryAppearance() {
        historyControls.showHighlight(model.highlightedAuthor?.name)
        historyTable.highlightedAuthor = model.highlightedAuthor
        historyTable.showsMergeLabel = model.showsMergeLabel
        if !model.showsMergeLabel { mergedPopover.close() }
        historyTable.setZoom(percent: model.historyZoomPercent, selecting: model.selectedCommit?.id)
        arrangeSectionPanes()
    }

    /// Reads the next page once the list is scrolled near its bottom (once per page).
    func loadHistoryNearBottom() {
        // A collapsed history counts loaded commits: its shown rows can stay few however many pages are read.
        let rows = historyTable.commits.count
        let loaded =
            model.collapsesMerges && !model.isSearchingHistory && model.focusedReference == nil
            ? model.snapshot?.commits.count ?? 0 : rows
        let table = historyTable.table
        guard !updating, model.section == .history, !historyPane.isHidden, loaded >= HistoryPaging.automaticMinimum,
            !model.displayedHistoryIsLoading, !model.historyPageFailed,
            HistoryPaging.isNearBottom(
                visibleMaxY: historyTable.scroll.documentVisibleRect.maxY, listHeight: table.bounds.height,
                rowHeight: table.rowHeight),
            model.displayedHistoryHasMore
        else { return }
        let identity = model.snapshot?.historyIdentity?.uuidString ?? model.snapshot?.head ?? ""
        let page = "\(model.snapshot?.root.path ?? "")|\(identity)|\(historyMode)|\(rows)|\(loaded)"
        guard lastAutomaticPage != page else { return }
        lastAutomaticPage = page
        moreHistory()
    }

    @objc func moreHistory() {
        if model.isSearchingHistory {
            model.loadMoreSearch()
        } else if model.focusedReference != nil {
            model.loadMoreFocusedHistory()
        } else {
            model.loadMore()
        }
    }

    func showAllBranches() {
        sidebarSelection = nil
        // Nothing narrower on screen: the link stops showing branches alone (hidden ones stay hidden).
        if !model.isSearchingHistory, model.focusedReference == nil, !model.branchFilters.only.isEmpty {
            model.clearBranchFilters(only: true, hidden: false)
            return
        }
        if model.isSearchingHistory {
            historyControls.search.stringValue = ""
            model.searchHistory("", field: model.searchField)
        }
        model.showAllHistory()
        rebuildSidebar()
    }

    func chooseSearchField(_ field: HistorySearchField) {
        model.searchHistory(historyControls.search.stringValue, field: field)
        updateHistoryScope()
        rebuildSidebar()
    }

    func searchHistory(_ query: String) {
        guard model.searchQuery != query else { return }
        sidebarSelection = nil
        if model.section != .history { model.section = .history }
        model.searchHistory(query, field: model.searchField)
        rebuildSidebar()
    }

    /// ⌘F: focus the history search.
    func focusSearch() {
        if model.section != .history { model.section = .history }
        view.window?.makeFirstResponder(historyControls.search)
    }

    /// Selects the commit and scrolls to it; inside a collapsed merge that merge (only it) expands first.
    func selectCommit(id: String, revealing: Bool = true) {
        if revealing, model.focusedReference == nil, model.collapsedMerge(hiding: id) != nil {
            model.reveal(id) { [weak self] in self?.selectCommit(id: id, revealing: false) }
            return
        }
        guard
            let commit = historyTable.commits.first(where: { $0.id == id })
                ?? model.snapshot?.commits.first(where: { $0.id == id })
        else { return }
        model.select(commit)
        historyTable.scrollToCommit(id)
    }

    func jumpTo(_ reference: GitReference, revealing: Bool = true) {
        let id = reference.commit
        if revealing, model.collapsedMerge(hiding: id) != nil {
            model.reveal(id) { [weak self] in self?.jumpTo(reference, revealing: false) }
            return
        }
        model.section = .history
        if let commit = model.snapshot?.commits.first(where: { $0.id == id }) {
            model.showAllHistory(selecting: commit)
            historyTable.select(id)
            historyTable.scrollToCommit(id)
        } else {
            model.focusHistory(on: reference)
        }
        rebuildSidebar()
    }
}
