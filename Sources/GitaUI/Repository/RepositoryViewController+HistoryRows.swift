import AppKit
import GitaCore

/// What the history rows show beyond the commit: merge flair and its commit list, Status chips, and what clicking
/// them opens.
extension RepositoryViewController: HistoryTableDelegate {
    var historyCommits: [GitCommit] { historyTable.commits }
    /// The remote branches the shown list was drawn with.
    var remoteReferenceNames: Set<String> { historyTable.list?.signature.remoteNames ?? [] }

    func historyDidSelect(_ commit: GitCommit) {
        guard !updating else { return }
        if model.section == .changes { model.section = .history }
        model.select(commit)
    }

    func historyDidChangeSelection(_ selection: HistorySelection) {
        guard !updating else { return }
        if model.section == .changes { model.section = .history }
        switch selection {
        case .none, .commit:
            // Handled by historyDidSelect / historyDidDeselect; ensure multi/working-changes overlay clears.
            if case .commit(let id) = selection {
                model.graphState.isReviewingWorkingChanges = false
                model.graphState.historySelection = .commit(id)
                model.graphState.compare = nil
                model.graphState.compareTask?.cancel()
            } else {
                model.graphState.historySelection = .none
            }
            syncHistoryDetailOverlay()
        case .pair, .many:
            model.selectHistory(selection)
            syncHistoryDetailOverlay()
        }
    }

    func historyDidDeselect() {
        guard !updating, model.section == .history else { return }
        model.deselectCommit()
    }

    func historyDidScroll() { loadHistoryNearBottom() }

    func historyShowReferences(of commitID: String, rect: NSRect, in view: NSView) {
        showReferences(of: commitID, rect: rect, in: view)
    }

    func historyOpenReference(_ reference: ReferenceBadge, commitID _: String) { openReference(reference) }

    func historyReferenceMenu(_ reference: ReferenceBadge, commitID: String) -> NSMenu? {
        referenceMenu(reference, commitID: commitID)
    }

    // MARK: Status chips

    func historyChipCandidates() -> Set<String> {
        var candidates = Set(model.signaledCommitIDs)
        candidates.formUnion(agentsByCommit.keys)
        candidates.formUnion(unpushed.ids)
        if let live = model.vercelContext?.production?.commit { candidates.insert(live) }
        return candidates
    }

    func historyChips(for commit: GitCommit) -> [HistoryChip] {
        let items = model.signals(for: commit).filter { $0.kind != .agent }
        let agents = agentsByCommit[commit.id] ?? []
        let context = model.vercelContext
        let live = context?.production.flatMap { $0.commit == commit.id ? $0 : nil }
        let notPushed = unpushed.ids.contains(commit.id)
        guard !items.isEmpty || !agents.isEmpty || live != nil || notPushed else { return [] }
        let liveItem = live == nil ? nil : model.allSignals.first { context?.isLive($0) == true }
        let signals = model.vercelSignals
        let errors = signals?.errors.flatMap { $0.deploymentID == live?.deploymentID ? $0 : nil }
        return HistoryChips.make(
            .init(
                items: items, agents: agents, notPushed: notPushed, live: live, liveItem: liveItem, errors: errors,
                rollout: signals?.rollout))
    }

    /// A Status chip: provider facts open in place in the Commit tab; an agent opens its row in the Agents pane.
    func historyOpenChip(_ target: HistoryChip.Target, commitID: String) {
        switch target {
        case .provider(let item):
            showCommitTab(of: commitID)
            rebuildCommitDetail()
            commitDetail.focus(item)
        case .agent(let session):
            showAgentsPane(expanding: session.id)
        case .url:
            // Live production outside the listed deployments: its facts are in the Commit tab.
            showCommitTab(of: commitID)
        case .none: break
        }
    }

    private func showCommitTab(of commitID: String) {
        if model.selectedCommit?.id != commitID { selectCommit(id: commitID) }
        if !model.showsHistoryDetails { model.toggleHistoryDetails() }
        selectDetailTab(.commit)
    }

    // MARK: Merges

    /// Who merged `commit` and how many commits it brought in.
    func historyFlair(for commit: GitCommit) -> MergeFlair? {
        guard !model.isSearchingHistory else { return nil }
        let squashTip = model.squashTip(of: commit)
        guard commit.parents.count > 1 || squashTip != nil else { return nil }
        return MergeFlairPresenter.flair(
            .init(
                commit: commit, squashTip: squashTip, mergedCount: mergedCommitIDs(commit).count,
                mergedBy: ProviderSignalQuery(signals: model.allSignals).mergedBy(commit.id),
                references: model.snapshot?.references ?? [],
                expanded: model.collapsesMerges && model.focusedReference == nil && model.inlineAuthor == nil
                    && model.isMergeExpanded(commit.id)))
    }

    /// Commits a merge brought in, within the loaded history (bounded walk, cached per history reload).
    private func mergedCommitIDs(_ merge: GitCommit) -> [String] {
        // The whole loaded history: a collapsed one leaves these very commits out of the shown rows.
        guard !model.isSearchingHistory else { return [] }
        return mergedCache.ids(of: merge, squashTip: model.squashTip(of: merge), history: model.mergeHistory)
    }

    func historyMergeChip(_ event: HistoryMergeChipEvent) {
        switch event {
        case .hover(let id, let rect, let view):
            mergedPopover.chipHovered(id, rect: rect, in: view) { mergedCommitsList(id) }
        case .hoverEnded: mergedPopover.chipHoverEnded()
        case .click(let id, let rect, let view):
            mergedPopover.chipClicked(id, rect: rect, in: view) { mergedCommitsList(id) }
        case .hide(let id):
            mergedPopover.close()
            model.collapseMerge(id)
        }
    }

    /// The list of commits the merge `id` brought in, with Show / Hide in History for a collapsed history.
    private func mergedCommitsList(_ id: String) -> MergedCommitsView? {
        guard let merge = historyTable.commit(id) else { return nil }
        let commits = MergedCommitCache.commits(mergedCommitIDs(merge), in: model.mergeHistory)
        guard !commits.isEmpty else { return nil }
        var action: (title: String, run: () -> Void)?
        if model.collapsesMerges, model.focusedReference == nil, model.inlineAuthor == nil {
            let expanded = model.isMergeExpanded(id)
            action = (
                expanded ? String(localized: "Hide in History") : String(localized: "Show in History"),
                { [weak self] in
                    self?.mergedPopover.close()
                    if expanded { self?.model.collapseMerge(id) } else { self?.model.expandMerge(id) }
                }
            )
        }
        return MergedCommitsView(commits: commits, squashed: model.squashTip(of: merge) != nil, action: action) {
            [weak self] commit in
            self?.mergedPopover.close()
            self?.selectCommit(id: commit.id)
        }
    }
}
