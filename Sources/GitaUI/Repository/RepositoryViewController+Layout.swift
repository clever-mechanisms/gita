import AppKit
import GitaCore

/// The window's view hierarchy: sidebar · content · Agents pane, and in the content the strip, the operation bar, the
/// history over the detail pane, the provider pages and the welcome screen.
extension RepositoryViewController {
    func buildLayout() {
        buildOuterSplit()
        buildContent()
        buildHistoryPane()
        buildDetailPane()
        Style.fill(providerPage, in: pagePane)
        Style.fill(welcome, in: historyPane)
        buildWelcome()
    }

    private func buildOuterSplit() {
        let split = outerSplit
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(sidebarView)
        split.addArrangedSubview(content)
        split.addArrangedSubview(agentsPane)
        sidebarView.widthAnchor.constraint(greaterThanOrEqualToConstant: RepositoryLayout.sidebarMinimum).isActive =
            true
        sidebarView.widthAnchor.constraint(lessThanOrEqualToConstant: RepositoryLayout.sidebarMaximum).isActive = true
        agentsPane.widthAnchor.constraint(greaterThanOrEqualToConstant: RepositoryLayout.agentsPaneMinimum)
            .isActive = true
        agentsPane.widthAnchor.constraint(lessThanOrEqualToConstant: RepositoryLayout.agentsPaneMaximum).isActive = true
        split.setHoldingPriority(.init(260), forSubviewAt: 0)
        split.setHoldingPriority(.init(259), forSubviewAt: 2)
        agentsPane.isHidden = !agentsPaneShown
        Style.fill(split, in: view)
        split.setPosition(panes.sidebarWidth, ofDividerAt: 0)
    }

    private func buildContent() {
        historyControls.search.stringValue = model.searchQuery
        historyControls.onSearch = { [weak self] query in self?.searchHistory(query) }
        historyControls.onChooseField = { [weak self] field in self?.chooseSearchField(field) }
        operationBar.onReview = { [weak self] in self?.reviewConflicts() }
        for child in [strip, operationBar, historyPane, pagePane] as [NSView] {
            content.addSubview(child)
            child.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate(
            pinnedSides(strip, operationBar, historyPane, pagePane) + [
                strip.topAnchor.constraint(equalTo: content.topAnchor), stripHeight,
                operationBar.topAnchor.constraint(equalTo: strip.bottomAnchor), operationHeight,
                historyPane.topAnchor.constraint(equalTo: operationBar.bottomAnchor),
                historyPane.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                pagePane.topAnchor.constraint(equalTo: content.topAnchor),
                pagePane.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
    }

    /// Leading and trailing edges of `views` on the content's.
    private func pinnedSides(_ views: NSView...) -> [NSLayoutConstraint] {
        views.flatMap {
            [
                $0.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                $0.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            ]
        }
    }

    private func buildHistoryPane() {
        verticalSplit.isVertical = false
        verticalSplit.dividerStyle = .thin
        historyTable.onNeedsLayout = { [weak self] in self?.view.needsLayout = true }
        let scroll = historyTable.scroll
        historyTop.addSubview(scroll)
        historyTop.addSubview(loadMore)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        loadMore.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: historyTop.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: historyTop.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: historyTop.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: loadMore.topAnchor),
            loadMore.centerXAnchor.constraint(equalTo: historyTop.centerXAnchor),
            loadMore.bottomAnchor.constraint(equalTo: historyTop.bottomAnchor), historyFooterHeight,
        ])
        verticalSplit.addArrangedSubview(historyTop)
        verticalSplit.addArrangedSubview(bottom)
        Style.fill(verticalSplit, in: historyPane)
        historyTop.heightAnchor.constraint(greaterThanOrEqualToConstant: RepositoryLayout.historyTopMinimum)
            .isActive = true
        bottom.heightAnchor.constraint(greaterThanOrEqualToConstant: RepositoryLayout.detailMinimum).isActive = true
        bottom.color = Theme.inset
    }

    private func buildDetailPane() {
        filesSplit.isVertical = true
        filesSplit.dividerStyle = .thin
        filesSplit.addArrangedSubview(filePane)
        filesSplit.addArrangedSubview(codePane)
        filePane.widthAnchor.constraint(greaterThanOrEqualToConstant: RepositoryLayout.filePaneMinimum).isActive = true
        codePane.widthAnchor.constraint(greaterThanOrEqualToConstant: RepositoryLayout.codePaneMinimum).isActive = true
        filesSplit.setHoldingPriority(.init(260), forSubviewAt: 0)
        Style.fill(filesSplit, in: detailBody)
        Style.fill(commitDetail, in: detailBody)
        let lower = Style.stack([detailBar, detailBody, commitFooter], vertical: true, spacing: 0)
        lower.alignment = .leading
        Style.fill(lower, in: bottom)
        NSLayoutConstraint.activate([
            detailBar.widthAnchor.constraint(equalTo: lower.widthAnchor),
            detailBar.heightAnchor.constraint(equalToConstant: DetailBarView.height),
            detailBody.widthAnchor.constraint(equalTo: lower.widthAnchor),
            commitFooter.widthAnchor.constraint(equalTo: lower.widthAnchor),
        ])
        detailBody.setContentHuggingPriority(.init(1), for: .vertical)
        detailBar.setContentHuggingPriority(.required, for: .vertical)
    }

    private func buildWelcome() {
        let buttons = [
            (String(localized: "Open repository…"), "folder", #selector(AppDelegate.openRepository)),
            (String(localized: "Clone repository…"), "arrow.down", #selector(AppDelegate.cloneRepository)),
            (String(localized: "New repository…"), "plus", #selector(AppDelegate.initializeRepository)),
            (String(localized: "Open recent"), "clock", #selector(AppDelegate.openRecent)),
        ].map { Style.button($0.0, symbol: $0.1, target: nil, action: $0.2) }
        let title = Style.label(
            "Gitā", size: RepositoryLayout.welcomeTitleSize, weight: .semibold, color: Theme.text)
        let stack = Style.stack([title] + buttons, vertical: true, spacing: RepositoryLayout.welcomeSpacing)
        stack.alignment = .centerX
        welcome.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: welcome.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: welcome.centerYAnchor),
        ])
    }

    /// The history table's menu and its zoom; the table itself is `HistoryTableController`'s.
    func buildHistory() {
        historyTable.delegate = self
        historyTable.showsMergeLabel = model.showsMergeLabel
        historyTable.setZoom(percent: model.historyZoomPercent, selecting: nil)
        let menu = HistoryMenu.menu(target: nil)
        historyMenuVercel.model = model
        historyMenu.vercel = historyMenuVercel
        historyMenu.authorItem = { [weak self] in self?.authorMenuItem() }
        historyMenu.referenceItems = { [weak self] in
            guard let self, let commit = self.model.selectedCommit else { return [] }
            return self.referenceItems(for: commit)
        }
        historyMenu.commitItems = { [weak self] in
            guard let self, let commit = self.model.selectedCommit else { return [] }
            return self.commitItems(for: commit)
        }
        menu.delegate = historyMenu
        historyTable.table.menu = menu
    }

    /// The right-clicked commit's author, with Highlight (fade everyone else's commits) and Filter (only theirs).
    private func authorMenuItem() -> NSMenuItem? {
        guard let commit = model.selectedCommit else { return nil }
        let builder = AuthorMenuBuilder(
            highlighted: model.highlightedAuthor, lens: model.authorLens,
            highlight: { [weak self] author in self?.model.highlightAuthor(author) },
            filter: { [weak self] author in
                guard let self, let root = self.model.snapshot?.root else { return }
                self.commands?.openAuthorTab(author, in: root)
            })
        return builder.item(for: commit)
    }
}
