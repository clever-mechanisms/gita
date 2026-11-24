import AppKit

/// The dividers: placed once the window has its size, carried over between tabs, and the sidebar and Agents pane
/// shown or hidden.
extension RepositoryViewController {
    /// The window-level pane geometry a tab switch carries over (sidebar width and visibility, detail height), so
    /// switching to another checkout swaps the content without moving the panes.
    struct PaneGeometry {
        var sidebarWidth: CGFloat
        var sidebarHidden: Bool
        var bottomHeight: CGFloat
        var agentsWidth: CGFloat
        var sectionDividers = SectionPanes.DividerMemory()
    }

    var paneGeometry: PaneGeometry? {
        guard isViewLoaded, panes.positioned else { return nil }
        rememberSectionDividers(for: model.section)
        return PaneGeometry(
            sidebarWidth: sidebarView.isHidden
                ? panes.sidebarWidth : max(RepositoryLayout.sidebarMinimum, sidebarView.frame.width),
            sidebarHidden: sidebarView.isHidden, bottomHeight: panes.bottomHeight,
            agentsWidth: agentsPane.isHidden
                ? panes.agentsPaneWidth : max(RepositoryLayout.agentsPaneMinimum, agentsPane.frame.width),
            sectionDividers: panes.sectionDividers)
    }

    /// Takes the previous tab's geometry before this tab's view is laid out in the window.
    func adopt(_ geometry: PaneGeometry) {
        _ = view
        if panes.sectionDividers != geometry.sectionDividers {
            panes.sectionDividers = geometry.sectionDividers
            panes.historySplitSettled = false
        }
        if abs(panes.bottomHeight - geometry.bottomHeight) > 0.5 {
            panes.bottomHeight = geometry.bottomHeight
            panes.historySplitSettled = false
        }
        panes.sidebarWidth = geometry.sidebarWidth
        if sidebarView.isHidden != geometry.sidebarHidden {
            sidebarView.isHidden = geometry.sidebarHidden
            outerSplit.adjustSubviews()
        }
        if panes.positioned, !sidebarView.isHidden, abs(sidebarView.frame.width - panes.sidebarWidth) > 0.5 {
            outerSplit.setPosition(panes.sidebarWidth, ofDividerAt: 0)
        }
        panes.agentsPaneWidth = geometry.agentsWidth
        applyAgentsPaneVisibility()
        if panes.positioned, filesSplit.bounds.width > 0 {
            panes.isPlacingSectionPanes = true
            filesSplit.setPosition(panes.sectionDividers.filePaneWidth(for: model.section), ofDividerAt: 0)
            panes.isPlacingSectionPanes = false
        }
    }

    /// Right after the tab's view is laid out in the window: place the history/detail split now (not on the next turn
    /// of the run loop, which a tab that appears with its content already loaded would show as a jump).
    func settleLayout() {
        guard isViewLoaded, view.window != nil else { return }
        if !panes.historySplitSettled, verticalSplit.arrangedSubviews.count == 2,
            verticalSplit.bounds.height > RepositoryLayout.settledHeight
        {
            panes.historySplitSettled = true
            panes.positionedHistory = true
            positionHistorySplit()
        }
        if panes.positioned, !sidebarView.isHidden, abs(sidebarView.frame.width - panes.sidebarWidth) > 0.5 {
            outerSplit.setPosition(panes.sidebarWidth, ofDividerAt: 0)
            outerSplit.layoutSubtreeIfNeeded()
        }
        if panes.positioned, !agentsPane.isHidden, abs(agentsPane.frame.width - panes.agentsPaneWidth) > 0.5 {
            positionAgentsPane()
            outerSplit.layoutSubtreeIfNeeded()
        }
    }

    func positionPanesOnFirstLayout() {
        if !panes.positioned, view.bounds.width > RepositoryLayout.settledWidth {
            panes.positioned = true
            panes.isPlacingSectionPanes = true
            outerSplit.setPosition(panes.sidebarWidth, ofDividerAt: 0)
            positionAgentsPane()
            filesSplit.setPosition(panes.sectionDividers.filePaneWidth(for: model.section), ofDividerAt: 0)
            panes.isPlacingSectionPanes = false
        }
        guard !panes.positionedHistory, view.window != nil,
            verticalSplit.bounds.height > RepositoryLayout.settledHeight, verticalSplit.arrangedSubviews.count == 2
        else { return }
        panes.positionedHistory = true
        // Wait for the window/tab layout to settle before choosing the initial divider; the pre-window split can
        // still have zero height.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.view.window != nil, self.verticalSplit.arrangedSubviews.count == 2 else {
                self.panes.positionedHistory = false
                return
            }
            self.positionHistorySplit()
        }
    }

    func positionHistorySplit() {
        let height = verticalSplit.bounds.height
        guard height > 0 else { return }
        panes.isPlacingSectionPanes = true
        defer { panes.isPlacingSectionPanes = false }
        if SectionPanes(model.section).collapsesHistoryByDefault {
            applyChangesHistoryDivider()
        } else {
            historyTop.isHidden = false
            verticalSplit.setPosition(panes.historyDivider(height: height), ofDividerAt: 0)
        }
    }

    private func applyChangesHistoryDivider() {
        let target = panes.sectionDividers.changesHistoryHeight
        if target <= 0 {
            historyTop.isHidden = true
            verticalSplit.setPosition(0, ofDividerAt: 0)
            verticalSplit.adjustSubviews()
        } else {
            historyTop.isHidden = false
            let maxAllowed = max(
                RepositoryLayout.historyTopMinimum,
                verticalSplit.bounds.height - RepositoryLayout.detailMinimum - verticalSplit.dividerThickness)
            verticalSplit.setPosition(
                min(max(target, RepositoryLayout.historyTopMinimum), maxAllowed), ofDividerAt: 0)
        }
    }

    func rememberHistorySplit() {
        guard model.section == .history, verticalSplit.arrangedSubviews.count == 2,
            verticalSplit.bounds.height > 0, bottom.superview != nil, !verticalSplit.isSubviewCollapsed(historyTop)
        else { return }
        // The divider belongs to the remembered height: `positionHistorySplit` subtracts both, so a remember/restore
        // round trip (a tab switch, Changes and back) does not shrink the detail pane by a point each time.
        panes.bottomHeight = PaneState.detailHeight(bottom.frame.height, divider: verticalSplit.dividerThickness)
    }

    private func rememberSectionDividers(for section: Section) {
        if section == .history {
            rememberHistorySplit()
        } else if section == .changes, verticalSplit.arrangedSubviews.count == 2, verticalSplit.bounds.height > 0,
            historyTop.superview != nil
        {
            panes.sectionDividers.changesHistoryHeight =
                verticalSplit.isSubviewCollapsed(historyTop) ? 0 : historyTop.frame.height
        }
        if panes.positioned, filesSplit.bounds.width > 0, let left = filesSplit.arrangedSubviews.first,
            left.frame.width >= SectionPanes(section).filePaneMinimum - 1
        {
            panes.sectionDividers.setFilePaneWidth(left.frame.width, for: section)
        }
    }

    private var historyTopMinHeightConstraint: NSLayoutConstraint? {
        historyTop.constraints.first { $0.identifier == RepositoryLayout.historyTopMinimumID }
    }

    private var fileColumnMinWidthConstraint: NSLayoutConstraint? {
        filesSplit.arrangedSubviews.first?.constraints.first { $0.identifier == RepositoryLayout.fileColumnMinimumID }
    }

    /// Changes collapses history to 0 by default (remembered per section) with a 260 pt minimum left column; History
    /// shows the list and, when enabled, the details pane.
    func arrangeSectionPanes() {
        let previous = panes.activeSection
        if previous != model.section {
            rememberSectionDividers(for: previous)
            panes.activeSection = model.section
        }
        panes.isPlacingSectionPanes = true
        defer { panes.isPlacingSectionPanes = false }
        let spec = SectionPanes(model.section)
        fileColumnMinWidthConstraint?.constant = spec.filePaneMinimum
        historyTopMinHeightConstraint?.isActive = !spec.collapsesHistoryByDefault
        if model.section == .changes {
            if historyTop.superview == nil { verticalSplit.insertArrangedSubview(historyTop, at: 0) }
            if bottom.superview == nil { verticalSplit.addArrangedSubview(bottom) }
            if verticalSplit.bounds.height > 0 { applyChangesHistoryDivider() }
        } else if model.section == .history {
            if historyTop.superview == nil { verticalSplit.insertArrangedSubview(historyTop, at: 0) }
            historyTop.isHidden = false
            arrangeHistoryBottom(sectionChanged: previous != model.section)
        }
        if panes.positioned {
            if filesSplit.bounds.width <= 0 { bottom.layoutSubtreeIfNeeded() }
            if filesSplit.bounds.width > 0 {
                filesSplit.setPosition(panes.sectionDividers.filePaneWidth(for: model.section), ofDividerAt: 0)
            }
        }
    }

    private func arrangeHistoryBottom(sectionChanged: Bool) {
        if model.showsHistoryDetails {
            let needsPlace = bottom.superview == nil || sectionChanged
            if bottom.superview == nil { verticalSplit.addArrangedSubview(bottom) }
            if needsPlace, verticalSplit.bounds.height > 0 {
                verticalSplit.setPosition(panes.historyDivider(height: verticalSplit.bounds.height), ofDividerAt: 0)
            }
        } else {
            rememberHistorySplit()
            bottom.removeFromSuperview()
        }
    }

    /// Toolbar sidebar button.
    func toggleSidebar() {
        if !sidebarView.isHidden { panes.sidebarWidth = max(RepositoryLayout.sidebarMinimum, sidebarView.frame.width) }
        sidebarView.isHidden.toggle()
        outerSplit.adjustSubviews()
        if !sidebarView.isHidden { outerSplit.setPosition(panes.sidebarWidth, ofDividerAt: 0) }
        positionAgentsPane()
    }

    // MARK: Agents pane

    /// Shown in every window and tab once opened, until closed again (remembered across launches).
    static var agentsPaneShown: Bool { Preference.agentsPaneShown.bool() }
    var agentsPaneShown: Bool {
        get { Preference.agentsPaneShown.bool(model.defaults) }
        set { model.defaults.set(newValue, forKey: Preference.agentsPaneShown.rawValue) }
    }
    var isAgentsPaneShown: Bool { isViewLoaded && !agentsPane.isHidden }

    /// Toolbar Agents button, View ▸ Worktrees & Agents.
    func toggleAgentsPane() {
        agentsPaneShown = !isAgentsPaneShown
        applyAgentsPaneVisibility()
    }

    /// Opens the pane (if closed) on this session's or checkout's row.
    func showAgentsPane(expanding sessionID: String? = nil) {
        if !isAgentsPaneShown {
            agentsPaneShown = true
            applyAgentsPaneVisibility()
        }
        agentsPane.expand(sessionID: sessionID)
    }

    func applyAgentsPaneVisibility() {
        guard isViewLoaded else { return }
        let shown = agentsPaneShown
        guard agentsPane.isHidden == shown else { return }
        if !shown { panes.agentsPaneWidth = max(RepositoryLayout.agentsPaneMinimum, agentsPane.frame.width) }
        agentsPane.isHidden = !shown
        outerSplit.adjustSubviews()
        // A pane just unhidden has no frame until the split lays out: place the divider after that.
        outerSplit.layoutSubtreeIfNeeded()
        positionAgentsPane()
        if shown { refreshOverview() }
        MainToolbar.refreshAll()
    }

    func positionAgentsPane() {
        guard !agentsPane.isHidden, outerSplit.bounds.width > 0 else { return }
        let divider = outerSplit.dividerThickness
        let leading = sidebarView.isHidden ? 0 : sidebarView.frame.width + divider
        let width = panes.agentsWidth(total: outerSplit.bounds.width, leading: leading, divider: divider)
        guard abs(agentsPane.frame.width - width) > 0.5 else { return }
        outerSplit.setPosition(outerSplit.bounds.width - width - divider, ofDividerAt: 1)
        outerSplit.layoutSubtreeIfNeeded()
    }
}

extension RepositoryViewController: @MainActor NSSplitViewDelegate {
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        splitView === verticalSplit && subview === historyTop && model.section == .changes
    }

    func splitView(
        _ splitView: NSSplitView, shouldCollapseSubview subview: NSView, forDoubleClickOnDividerAt _: Int
    ) -> Bool {
        splitView === verticalSplit && subview === historyTop && model.section == .changes
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard !panes.isPlacingSectionPanes, notification.userInfo?["NSSplitViewDividerIndex"] != nil else { return }
        guard let split = notification.object as? NSSplitView else { return }
        if split === verticalSplit || split === filesSplit {
            rememberSectionDividers(for: model.section)
        }
    }
}
