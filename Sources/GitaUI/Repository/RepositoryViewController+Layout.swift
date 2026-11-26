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
        Style.fill(prWorkspace, in: pagePane)
        Style.fill(providerPage, in: prWorkspace.listHost)
        providerPage.setZoom(percent: model.historyZoomPercent)
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
        wireContentBanner()
        let banner = contentBanner
        let focusKey = PaneFocusKeyView { [weak self] event in self?.handlePaneFocusKey(event) ?? false }
        for child in [banner, strip, operationBar, bisectBanner, historyPane, pagePane, focusKey] as [NSView] {
            content.addSubview(child)
            child.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate(
            pinnedSides(banner, strip, operationBar, bisectBanner, historyPane, pagePane) + [
                banner.topAnchor.constraint(equalTo: content.topAnchor), bannerHeight,
                strip.topAnchor.constraint(equalTo: banner.bottomAnchor), stripHeight,
                operationBar.topAnchor.constraint(equalTo: strip.bottomAnchor), operationHeight,
                bisectBanner.topAnchor.constraint(equalTo: operationBar.bottomAnchor), bisectHeight,
                historyPane.topAnchor.constraint(equalTo: bisectBanner.bottomAnchor),
                historyPane.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                pagePane.topAnchor.constraint(equalTo: banner.bottomAnchor),
                pagePane.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                focusKey.widthAnchor.constraint(equalToConstant: 0),
                focusKey.heightAnchor.constraint(equalToConstant: 0),
            ])
        syncContentBanner()
    }

    private func wireContentBanner() {
        let banner = contentBanner
        banner.setAccessibilityIdentifier("content.banner")
        banner.onRetry = { [weak self] in self?.model.retryBanner() }
        banner.onDismiss = { [weak self] in self?.model.dismissBanner() }
        banner.onDetails = { [weak self] in
            guard let self else { return }
            ActivityWindowController.shared.show(model: self.model)
        }
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
        verticalSplit.delegate = self
        historyTable.onNeedsLayout = { [weak self] in self?.view.needsLayout = true }
        let scroll = historyTable.scroll
        let header = historyTable.headerClip
        let filters = historyControls.filterBar
        let sparkline = historyTable.velocitySparkline
        let working = historyTable.workingChangesRow
        for row in [header, filters, sparkline, working, scroll, loadMore] as [NSView] {
            historyTop.addSubview(row)
            row.translatesAutoresizingMaskIntoConstraints = false
        }
        let fullWidth = [header, filters, sparkline, working, scroll].flatMap { row in
            [
                row.leadingAnchor.constraint(equalTo: historyTop.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: historyTop.trailingAnchor),
            ]
        }
        let historyMinHeight = historyTop.heightAnchor.constraint(
            greaterThanOrEqualToConstant: RepositoryLayout.historyTopMinimum)
        historyMinHeight.identifier = RepositoryLayout.historyTopMinimumID
        NSLayoutConstraint.activate(
            fullWidth + [
                filters.topAnchor.constraint(equalTo: historyTop.topAnchor),
                filters.heightAnchor.constraint(equalToConstant: 26),
                sparkline.topAnchor.constraint(equalTo: filters.bottomAnchor), historyTable.sparklineHeight,
                header.topAnchor.constraint(equalTo: sparkline.bottomAnchor),
                header.heightAnchor.constraint(equalToConstant: historyTable.header.frame.height),
                working.topAnchor.constraint(equalTo: header.bottomAnchor), historyTable.workingRowHeight,
                scroll.topAnchor.constraint(equalTo: working.bottomAnchor),
                scroll.bottomAnchor.constraint(equalTo: loadMore.topAnchor),
                loadMore.centerXAnchor.constraint(equalTo: historyTop.centerXAnchor),
                loadMore.bottomAnchor.constraint(equalTo: historyTop.bottomAnchor), historyFooterHeight,
                historyMinHeight,
            ])
        verticalSplit.addArrangedSubview(historyTop)
        verticalSplit.addArrangedSubview(bottom)
        Style.fill(verticalSplit, in: historyPane)
        bottom.heightAnchor.constraint(greaterThanOrEqualToConstant: RepositoryLayout.detailMinimum).isActive = true
        bottom.color = Theme.inset
    }

    private func buildDetailPane() {
        filesSplit.isVertical = true
        filesSplit.dividerStyle = .thin
        filesSplit.delegate = self
        let fileColumn = Deck.vstack([filePane, commitFooter], spacing: 0)
        fileColumn.alignment = .leading
        filePane.widthAnchor.constraint(equalTo: fileColumn.widthAnchor).isActive = true
        commitFooter.widthAnchor.constraint(equalTo: fileColumn.widthAnchor).isActive = true
        filePane.setContentHuggingPriority(.init(1), for: .vertical)
        filePane.setContentCompressionResistancePriority(.init(1), for: .vertical)
        commitFooter.setContentHuggingPriority(.required, for: .vertical)
        commitFooter.setContentCompressionResistancePriority(.required, for: .vertical)

        filesSplit.addArrangedSubview(fileColumn)
        filesSplit.addArrangedSubview(codePane)
        let fileMinWidth = fileColumn.widthAnchor.constraint(
            greaterThanOrEqualToConstant: RepositoryLayout.filePaneMinimum)
        fileMinWidth.identifier = RepositoryLayout.fileColumnMinimumID
        fileMinWidth.isActive = true
        codePane.widthAnchor.constraint(greaterThanOrEqualToConstant: RepositoryLayout.codePaneMinimum).isActive = true
        filesSplit.setHoldingPriority(.init(260), forSubviewAt: 0)
        Style.fill(filesSplit, in: detailBody)
        Style.fill(commitDetail, in: detailBody)
        let lower = Style.stack([detailBar, detailBody], vertical: true, spacing: 0)
        lower.alignment = .leading
        Style.fill(lower, in: bottom)
        NSLayoutConstraint.activate([
            detailBar.widthAnchor.constraint(equalTo: lower.widthAnchor),
            detailBar.heightAnchor.constraint(equalToConstant: DetailBarView.height),
            detailBody.widthAnchor.constraint(equalTo: lower.widthAnchor),
        ])
        detailBody.setContentHuggingPriority(.init(1), for: .vertical)
        detailBar.setContentHuggingPriority(.required, for: .vertical)
    }

    private func buildWelcome() {
        let welcomeView = WelcomeView()
        welcomeView.defaults = model.defaults
        welcomeView.onOpen = { NSApp.sendAction(#selector(AppDelegate.openRepository), to: nil, from: nil) }
        welcomeView.onClone = { NSApp.sendAction(#selector(AppDelegate.cloneRepository), to: nil, from: nil) }
        welcomeView.onInitialize = {
            NSApp.sendAction(#selector(AppDelegate.initializeRepository), to: nil, from: nil)
        }
        welcomeView.onOpenRepository = { [weak self] url in self?.openWelcomeRepository(url) }
        welcomeView.onRemoveRecent = { [weak self] path in self?.removeRecentRepository(path, in: welcomeView) }
        welcomeView.onOfferInitialize = { [weak self] url in self?.confirmInitializeDroppedFolder(url) }
        Style.fill(welcomeView, in: welcome)
        welcomeView.reload(paths: model.recent)
        notificationObservations.append(
            NotificationCenter.default.addObserver(
                forName: .gitaPreferenceChanged, object: nil, queue: .main
            ) { [weak self, weak welcomeView] note in
                guard Preference(changed: note) == .recentRepositories else { return }
                MainActor.assumeIsolated {
                    if let self { welcomeView?.reload(paths: self.model.recent) }
                }
            })
    }

    private func openWelcomeRepository(_ url: URL) {
        if let commands {
            commands.openRepositoryTab(url)
        } else {
            model.open(url)
        }
    }

    private func removeRecentRepository(_ path: String, in welcomeView: WelcomeView) {
        if let commands {
            commands.removeFromRepositoryList([path])
        } else {
            let updated = RecentRepositories.removing([path], from: model.recent)
            model.defaults.set(updated, forKey: model.recentKey)
        }
        welcomeView.reload(paths: model.recent)
    }

    private func confirmInitializeDroppedFolder(_ folder: URL) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Initialize a repository here…")
        alert.informativeText = String(
            localized: "Create a new Git repository in “\(folder.lastPathComponent)” (\(folder.path))?")
        alert.addButton(withTitle: String(localized: "Initialize Repository"))
        alert.addButton(withTitle: String(localized: "Cancel")).keyEquivalent = "\u{1b}"
        AlertPresenter.shared.confirm(alert, on: view.window) { [weak self] in
            self?.initializeDroppedFolder(folder)
        }
    }

    private func initializeDroppedFolder(_ folder: URL) {
        Task { [weak self] in
            do {
                let root = try await GitService.initialize(existing: folder)
                self?.openWelcomeRepository(root)
            } catch {
                let retry = ContentBanner.RetryAction(title: String(localized: "Retry")) { [weak self] in
                    self?.initializeDroppedFolder(folder)
                }
                self?.model.showNonDestructiveError(
                    String(localized: "Initialize repository"), error.localizedDescription, retry: retry)
            }
        }
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

    // MARK: Inline Error Banner (§10.2)

    func syncContentBanner() {
        contentBanner.apply(model.contentBanner)
        bannerHeight.constant = model.contentBanner.isHidden ? 0 : ContentBannerView.height
    }

    // MARK: Keyboard Pane Focus (§10.4)

    enum FocusPane: Int, CaseIterable {
        case sidebar, history, files, diff
    }

    func focusPane(_ pane: FocusPane) {
        ensurePaneVisible(pane)
        guard let responder = paneResponder(for: pane), let host = paneHost(for: pane) else { return }
        view.window?.makeFirstResponder(responder)
        focusedPane = pane
        focusRing.removeFromSuperview()
        Style.fill(focusRing, in: host)
    }

    func cyclePaneFocus(forward: Bool = true) {
        let available = FocusPane.allCases.filter { paneHost(for: $0)?.isHidden == false }
        guard !available.isEmpty else { return }
        let current = currentFocusedPane() ?? focusedPane
        if let current, let index = available.firstIndex(of: current) {
            let offset = forward ? 1 : available.count - 1
            focusPane(available[(index + offset) % available.count])
        } else if let first = forward ? available.first : available.last {
            focusPane(first)
        }
    }

    private func handlePaneFocusKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        if let command = ShortcutStore.focusCommand(using: event, model.defaults) {
            switch command {
            case .focusSidebar: focusPane(.sidebar)
            case .focusHistory: focusPane(.history)
            case .focusFiles: focusPane(.files)
            case .focusDiff: focusPane(.diff)
            case .cyclePaneFocus: cyclePaneFocus()
            default: return false
            }
            return true
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 48, flags == [.control, .option] || flags == [.control, .option, .shift] {
            cyclePaneFocus(forward: !flags.contains(.shift))
            return true
        }
        return false
    }

    private func ensurePaneVisible(_ pane: FocusPane) {
        switch pane {
        case .sidebar:
            if sidebarView.isHidden { toggleSidebar() }
        case .history:
            if !SectionPanes(model.section).showsHistoryPane { model.section = .history }
        case .files, .diff:
            if !SectionPanes(model.section).showsHistoryPane { model.section = .history }
            if model.section == .history, !model.showsHistoryDetails {
                model.defaults.set(true, forKey: Preference.showsHistoryDetails.rawValue)
                arrangeSectionPanes()
            }
            if detailTab == .commit { selectDetailTab(.changes) }
        }
    }

    private func paneHost(for pane: FocusPane) -> NSView? {
        switch pane {
        case .sidebar: sidebarView
        case .history: historyTop
        case .files: filePane
        case .diff: codePane
        }
    }

    private func paneResponder(for pane: FocusPane) -> NSResponder? {
        switch pane {
        case .sidebar: sidebarView.repositoryPane.list.table
        case .history: historyTable.table
        case .files:
            switch filePane.content {
            case .commitFiles: filePane.commitFiles.outline
            case .localChanges: filePane.unstaged.list.outline
            case .tree: filePane.tree
            }
        case .diff: codePane.diffView.table
        }
    }

    private func currentFocusedPane() -> FocusPane? {
        guard let responder = view.window?.firstResponder as? NSView else { return nil }
        return FocusPane.allCases.first { pane in
            paneHost(for: pane).map { responder === $0 || responder.isDescendant(of: $0) } ?? false
        }
    }
}

@MainActor
final class PaneFocusRingView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.borderColor = Theme.accent.cgColor
        layer?.borderWidth = 2
        layer?.cornerRadius = 4
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("PaneFocusRingView is built in code") }

    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func updateLayer() {
        layer?.borderColor = Theme.accent.cgColor
    }
    override var wantsUpdateLayer: Bool { true }
}

@MainActor
private final class PaneFocusKeyView: NSView {
    private let onKey: (NSEvent) -> Bool

    init(onKey: @escaping (NSEvent) -> Bool) {
        self.onKey = onKey
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("PaneFocusKeyView is built in code") }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKey(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
}
