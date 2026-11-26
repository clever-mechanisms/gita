import AppKit
import GitaCore

/// Pure height math for the collapsible `REPOSITORIES` drawer (`≤40%` of sidebar height when expanded).
enum SidebarSplitLayout {
    static let collapsedHeight: CGFloat = 26
    static let expandedMinimum: CGFloat = 74
    static let maxShare: CGFloat = 0.40
    static let defaultShare: CGFloat = 0.28

    static func maxHeight(totalHeight: CGFloat, dividerThickness: CGFloat) -> CGFloat {
        let available = max(0, totalHeight - dividerThickness)
        return max(collapsedHeight, floor(available * maxShare))
    }

    static func clampedHeight(
        desired: CGFloat, totalHeight: CGFloat, dividerThickness: CGFloat, collapsed: Bool
    ) -> CGFloat {
        guard !collapsed else { return collapsedHeight }
        guard totalHeight > 0 else { return max(expandedMinimum, desired) }
        let maximum = maxHeight(totalHeight: totalHeight, dividerThickness: dividerThickness)
        let minimum = min(maximum, expandedMinimum)
        let target = desired > 0 ? desired : floor(max(0, totalHeight - dividerThickness) * defaultShare)
        return min(maximum, max(minimum, target))
    }

    static func dividerPosition(
        desired: CGFloat, totalHeight: CGFloat, dividerThickness: CGFloat, collapsed: Bool,
        position: SidebarRepositoriesPosition
    ) -> CGFloat {
        let drawerHeight = clampedHeight(
            desired: desired, totalHeight: totalHeight, dividerThickness: dividerThickness, collapsed: collapsed)
        switch position {
        case .top: return drawerHeight
        case .bottom: return max(0, totalHeight - dividerThickness - drawerHeight)
        }
    }

    static func dividerBounds(
        totalHeight: CGFloat, dividerThickness: CGFloat, collapsed: Bool, position: SidebarRepositoriesPosition
    ) -> (min: CGFloat, max: CGFloat) {
        let available = max(0, totalHeight - dividerThickness)
        let maxHeight = maxHeight(totalHeight: totalHeight, dividerThickness: dividerThickness)
        let drawerMin = collapsed ? collapsedHeight : min(maxHeight, expandedMinimum)
        let drawerMax = collapsed ? collapsedHeight : maxHeight
        switch position {
        case .top: return (drawerMin, drawerMax)
        case .bottom: return (max(0, available - drawerMax), max(0, available - drawerMin))
        }
    }
}

/// Split sidebar: pinned collapsible `REPOSITORIES` drawer (`SidebarRepositoriesPane`) and the open repository's
/// scoped filter, pages, recent branches, refs, and stashes (`SidebarRepositoryPane`), ordered per user preference.
@MainActor
final class RepositorySidebarView: NSView, NSSplitViewDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var onOpenCheckout: ((URL) -> Void)?
    var onOpenInNewTab: ((URL) -> Void)?
    var onNavigate: ((SidebarSelection) -> Void)?
    var onReference: ((GitReference) -> Void)?
    var onStash: ((GitStash) -> Void)?
    var referenceMenu: ((GitReference) -> NSMenu?)?
    var stashMenu: ((GitStash) -> NSMenu?)?
    /// The Remotes group or one remote: Manage Remotes… and friends.
    var remoteMenu: ((String?) -> NSMenu?)?
    /// A branch row's pin, show-only or hide button.
    var onFilter: ((GitReference, BranchFilters.Kind) -> Void)?
    var checkoutMenu: ((String, Bool) -> NSMenu?)?
    /// A repository row in Repositories: the checkout's actions plus Remove from List.
    var repositoryMenu: ((Repository) -> NSMenu?)?
    /// §6d safe drop handlers (menu / confirmation sheets only).
    var onDropBranch: ((String, GitReference, NSView?) -> Void)?
    var onDropCommits: (([String], GitReference) -> Void)?
    /// The event being handled (selection by arrow keys opens rows; tests send their own).
    var currentEventType: () -> NSEvent.EventType? = { NSApp.currentEvent?.type }
    /// Modifier flags for click-matrix testing without fabricating system events.
    var currentModifiers: () -> NSEvent.ModifierFlags = { [] }

    let split = DeckSplitView()
    let repositoriesPane: SidebarRepositoriesPane
    let repositoryPane: SidebarRepositoryPane

    var rows: [Row] { repositoryPane.rows + repositoriesPane.rows }

    private let state: SidebarState
    private var input = Input()
    private var preferenceObserver: NSObjectProtocol?
    private var appliedPosition: SidebarRepositoriesPosition?
    private var positioningSplit = false
    private var lastSplitHeight: CGFloat = 0

    /// Forgets the open-or-closed state of repositories removed from the list (any spelling of their paths).
    static func forgetRepositories(_ paths: [String]) {
        SidebarState.shared(Preference.store).forgetRepositories(paths)
    }

    init(state: SidebarState) {
        self.state = state
        repositoriesPane = SidebarRepositoriesPane(state: state)
        repositoryPane = SidebarRepositoryPane(state: state)
        super.init(frame: .zero)
        configureSplit()
        wirePanes()
        preferenceObserver = NotificationCenter.default.addObserver(
            forName: .gitaPreferenceChanged, object: nil, queue: .main
        ) { [weak self] note in
            let changed = Preference(changed: note)
            guard changed == .sidebarRepositoryOrder || changed == .sidebarRepositoriesPosition else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                if changed == .sidebarRepositoryOrder {
                    guard !self.rows.isEmpty else { return }
                    self.repositoriesPane.rebuild()
                } else if self.appliedPosition != self.state.repositoriesPosition {
                    self.applyRepositoriesPosition()
                }
            }
        }
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    isolated deinit {
        if let preferenceObserver { NotificationCenter.default.removeObserver(preferenceObserver) }
    }

    private func configureSplit() {
        split.isVertical = false
        split.dividerStyle = .thin
        split.delegate = self
        arrangeSplitPanes()
        Style.fill(split, in: self)
    }

    func applyRepositoriesPosition() {
        arrangeSplitPanes()
        if split.bounds.height > 0 {
            positioningSplit = true
            split.adjustSubviews()
            positioningSplit = false
            applySplitPosition()
        }
    }

    private func arrangeSplitPanes() {
        let position = state.repositoriesPosition
        appliedPosition = position
        let ordered: [NSView] =
            position == .top ? [repositoriesPane, repositoryPane] : [repositoryPane, repositoriesPane]
        if split.arrangedSubviews != ordered {
            positioningSplit = true
            for subview in split.arrangedSubviews { subview.removeFromSuperview() }
            for subview in ordered { split.addArrangedSubview(subview) }
            positioningSplit = false
        }
        let repositoriesIndex = position == .top ? 0 : 1
        split.setHoldingPriority(.init(260), forSubviewAt: repositoriesIndex)
        split.setHoldingPriority(.init(240), forSubviewAt: 1 - repositoriesIndex)
    }

    private func wirePanes() {
        repositoriesPane.sortMenu = { [weak self] in self?.repositoryOrderMenu() }
        repositoriesPane.onCollapseChange = { [weak self] _ in self?.applySplitPosition() }
        repositoriesPane.onRebuildRequested = { [weak self] in self?.repositoriesPane.rebuild() }
        repositoryPane.onRebuildRequested = { [weak self] in self?.repositoryPane.rebuild() }

        wireList(repositoryPane.list, offset: { 0 })
        wireList(repositoriesPane.list, offset: { [weak self] in self?.repositoryPane.rows.count ?? 0 })
        repositoryPane.filter.target = self
        repositoryPane.filter.action = #selector(filterChanged)
    }

    private func wireList(_ paneList: SidebarPaneList, offset: @escaping @MainActor () -> Int) {
        paneList.currentEventType = { [weak self] in self?.currentEventType() }
        paneList.currentModifiers = { [weak self] in self?.currentModifiers() ?? [] }
        paneList.onClickRow = { [weak self] local in self?.click(offset() + local) }
        paneList.onDoubleClickRow = { [weak self] local in self?.secondClick(offset() + local) }
        paneList.onActivateRow = { [weak self] local, fromKeyboard in
            self?.activate(offset() + local, fromKeyboard: fromKeyboard)
        }
        paneList.onChangeGroupRow = { [weak self] local, change in
            self?.changeGroup(offset() + local, change) ?? false
        }
        paneList.onRowMenu = { [weak self] local in self?.menu(offset() + local) }

        paneList.actions.onOpenCheckout = { [weak self] url, newTab in self?.openCheckout(url, inNewTab: newTab) }
        paneList.actions.onNavigate = { [weak self] id in self?.onNavigate?(id) }
        paneList.actions.onReference = { [weak self] ref, newTab in self?.openReference(ref, inNewTab: newTab) }
        paneList.actions.onStash = { [weak self] stash in self?.onStash?(stash) }
        paneList.actions.onFilter = { [weak self] ref, kind in self?.onFilter?(ref, kind) }
        paneList.actions.referenceMenu = { [weak self] ref in self?.referenceMenu?(ref) }
        paneList.actions.stashMenu = { [weak self] stash in self?.stashMenu?(stash) }
        paneList.actions.remoteMenu = { [weak self] name in self?.remoteMenu?(name) }
        paneList.actions.checkoutMenu = { [weak self] path, isMain in self?.checkoutMenu?(path, isMain) }
        paneList.actions.repositoryMenu = { [weak self] repo in self?.repositoryMenu?(repo) }
        paneList.actions.onDropBranch = { [weak self, weak paneList] sourceFullName, target, row in
            let anchor = paneList?.table.rowView(atRow: row, makeIfNecessary: false)
            self?.onDropBranch?(sourceFullName, target, anchor)
        }
        paneList.actions.onDropCommits = { [weak self] commitIDs, target in
            self?.onDropCommits?(commitIDs, target)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.sidebar.setFill()
        dirtyRect.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        guard abs(split.bounds.height - lastSplitHeight) > 0.5 else { return }
        lastSplitHeight = split.bounds.height
        applySplitPosition()
    }

    // MARK: Split sizing

    func applySplitPosition() {
        guard split.bounds.height > 0, !repositoryPane.isHidden else { return }
        let position = SidebarSplitLayout.dividerPosition(
            desired: state.repositoriesHeight, totalHeight: split.bounds.height,
            dividerThickness: split.dividerThickness, collapsed: repositoriesPane.isCollapsed,
            position: state.repositoriesPosition)
        positioningSplit = true
        split.setPosition(position, ofDividerAt: 0)
        positioningSplit = false
    }

    func splitView(
        _ splitView: NSSplitView, constrainMinCoordinate _: CGFloat, ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard dividerIndex == 0, !repositoryPane.isHidden else { return 0 }
        return SidebarSplitLayout.dividerBounds(
            totalHeight: splitView.bounds.height, dividerThickness: splitView.dividerThickness,
            collapsed: repositoriesPane.isCollapsed, position: state.repositoriesPosition
        ).min
    }

    func splitView(
        _ splitView: NSSplitView, constrainMaxCoordinate _: CGFloat, ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard dividerIndex == 0, !repositoryPane.isHidden else { return splitView.bounds.height }
        return SidebarSplitLayout.dividerBounds(
            totalHeight: splitView.bounds.height, dividerThickness: splitView.dividerThickness,
            collapsed: repositoriesPane.isCollapsed, position: state.repositoriesPosition
        ).max
    }

    func splitView(_: NSSplitView, canCollapseSubview _: NSView) -> Bool { false }
    func splitView(_: NSSplitView, shouldAdjustSizeOfSubview subview: NSView) -> Bool {
        subview !== repositoriesPane
    }

    func splitViewDidResizeSubviews(_: Notification) {
        guard !positioningSplit, !repositoriesPane.isCollapsed, !repositoryPane.isHidden, split.bounds.height > 0
        else { return }
        let maxHeight = SidebarSplitLayout.maxHeight(
            totalHeight: split.bounds.height, dividerThickness: split.dividerThickness)
        if repositoriesPane.frame.height > maxHeight + 0.5 {
            applySplitPosition()
            return
        }
        state.repositoriesHeight = repositoriesPane.frame.height
    }

    // MARK: Updates

    func update(_ next: Input) {
        guard next != input || rows.isEmpty else { return }
        input = next
        let hideRepositoryPane = input.currentRoot == nil
        if repositoryPane.isHidden != hideRepositoryPane {
            repositoryPane.isHidden = hideRepositoryPane
            split.adjustSubviews()
        }
        repositoriesPane.update(input)
        repositoryPane.update(input)
        applySplitPosition()
    }

    func loadRecentBranchesIfNeeded(for snapshot: RepositorySnapshot, service: GitService) {
        repositoryPane.loadRecentBranchesIfNeeded(for: snapshot, service: service)
    }

    // MARK: Unified forwarding & clicks

    private func targetList(for unifiedRow: Int) -> (list: SidebarPaneList, row: Int)? {
        let count = repositoryPane.rows.count
        if unifiedRow >= 0, unifiedRow < count { return (repositoryPane.list, unifiedRow) }
        let repoRow = unifiedRow - count
        if repoRow >= 0, repoRow < repositoriesPane.rows.count { return (repositoriesPane.list, repoRow) }
        return nil
    }

    func numberOfRows(in _: NSTableView) -> Int { rows.count }
    func tableView(_: NSTableView, heightOfRow row: Int) -> CGFloat { rows[row].height }
    func tableView(_: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard let target = targetList(for: row) else { return false }
        return target.list.tableView(target.list.table, shouldSelectRow: target.row)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        guard let target = targetList(for: row) else { return nil }
        return target.list.tableView(tableView, rowViewForRow: target.row)
    }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard let target = targetList(for: row) else { return nil }
        return target.list.tableView(tableView, viewFor: column, row: target.row)
    }

    func click(_ row: Int) {
        guard let target = targetList(for: row) else { return }
        target.list.performClick(target.row)
    }

    func secondClick(_ row: Int) {
        guard let target = targetList(for: row) else { return }
        target.list.performSecondClick(target.row)
    }

    func activate(_ row: Int, fromKeyboard: Bool) {
        guard let target = targetList(for: row) else { return }
        target.list.performActivate(target.row, fromKeyboard: fromKeyboard, modifiers: currentModifiers())
    }

    @discardableResult
    func changeGroup(_ row: Int, _ change: SidebarTable.GroupChange) -> Bool {
        guard let target = targetList(for: row) else { return false }
        return target.list.performChangeGroup(target.row, change)
    }

    func menu(_ row: Int) -> NSMenu? {
        guard let target = targetList(for: row) else { return nil }
        return target.list.performMenu(target.row)
    }

    @objc func filterChanged() {
        repositoryPane.filterChanged()
    }

    /// The repositories header menu: sort order and sidebar position, current choices checked.
    func repositoryOrderMenu() -> NSMenu {
        let menu = NSMenu()
        for (order, title) in [
            (RepositoryListOrder.name, String(localized: "Sort by Name")),
            (.recent, String(localized: "Sort by Recently Opened")),
            (.status, String(localized: "Sort by Status")),
        ] {
            let item = MenuAction(title) { [state] in state.setRepositoryOrder(order) }
            item.state = order == state.repositoryOrder ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for position in SidebarRepositoriesPosition.allCases {
            let item = MenuAction(position.menuTitle) { [state] in state.setRepositoriesPosition(position) }
            item.state = position == state.repositoriesPosition ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func openCheckout(_ url: URL, inNewTab: Bool) {
        let targetKey = WindowAgents.key(url)
        if let owner = input.repositories.first(where: { repo in
            WindowAgents.key(repo.root) == targetKey
                || repo.checkouts.contains(where: { WindowAgents.key(URL(fileURLWithPath: $0.path)) == targetKey })
        }) {
            state.recordCheckout(url, for: owner.root)
        }
        if inNewTab {
            (onOpenInNewTab ?? onOpenCheckout)?(url)
        } else {
            onOpenCheckout?(url)
        }
    }

    private func openReference(_ reference: GitReference, inNewTab: Bool) {
        if inNewTab, let worktreePath = input.worktreeBranches[reference.name] {
            (onOpenInNewTab ?? onOpenCheckout)?(URL(fileURLWithPath: worktreePath, isDirectory: true))
            return
        }
        onReference?(reference)
    }
}
