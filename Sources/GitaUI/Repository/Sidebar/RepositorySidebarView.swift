import AppKit
import GitaCore

/// Sidebar: REPOSITORIES, each expandable to its checkouts (main checkout and worktrees)
/// with the agent working there and ahead/dirty meta, then the selected repository's own items: Local Changes,
/// All Commits, Branches, Remotes, Tags, Stashes, Pull Requests, Workflows, Deployments. Virtualized (NSTableView).
/// `SidebarRowBuilder` builds the rows; this view shows them and turns clicks into the callbacks below.
@MainActor
final class RepositorySidebarView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private enum Metrics {
        static let filterInset: CGFloat = 10
        static let filterTop: CGFloat = 8
        static let listGap: CGFloat = 2
        static let listInset: CGFloat = 8
    }

    var onOpenCheckout: ((URL) -> Void)?
    var onNavigate: ((SidebarSelection) -> Void)?
    var onReference: ((GitReference) -> Void)?
    var onStash: ((GitStash) -> Void)?
    var referenceMenu: ((GitReference) -> NSMenu?)?
    /// The Remotes group or one remote: Manage Remotes… and friends.
    var remoteMenu: ((String?) -> NSMenu?)?
    /// A branch row's pin, show-only or hide button.
    var onFilter: ((GitReference, BranchFilters.Kind) -> Void)?
    var checkoutMenu: ((String, Bool) -> NSMenu?)?
    /// A repository row in Repositories: the checkout's actions plus Remove from List.
    var repositoryMenu: ((Repository) -> NSMenu?)?
    /// The event being handled (selection by arrow keys opens rows; tests send their own).
    var currentEventType: () -> NSEvent.EventType? = { NSApp.currentEvent?.type }

    let table = SidebarTable()
    let filter = NSSearchField()
    private let state: SidebarState
    private var input = Input()
    private(set) var rows: [Row] = []
    private var updating = false
    private var lastQuery = ""
    private var orderObserver: NSObjectProtocol?

    /// Forgets the open-or-closed state of repositories removed from the list (any spelling of their paths).
    static func forgetRepositories(_ paths: [String]) {
        SidebarState.shared(Preference.store).forgetRepositories(paths)
    }

    init(state: SidebarState) {
        self.state = state
        super.init(frame: .zero)
        configureTable()
        layoutViews()
        orderObserver = NotificationCenter.default.addObserver(
            forName: .gitaPreferenceChanged, object: nil, queue: .main
        ) { [weak self] note in
            guard Preference(changed: note) == .sidebarRepositoryOrder else { return }
            MainActor.assumeIsolated {
                guard let self, !self.rows.isEmpty else { return }
                self.rebuild()
            }
        }
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    isolated deinit {
        if let orderObserver { NotificationCenter.default.removeObserver(orderObserver) }
    }

    private func configureTable() {
        table.addTableColumn(NSTableColumn(identifier: .init("sidebar")))
        table.headerView = nil
        table.intercellSpacing = .zero
        table.style = .plain
        table.backgroundColor = .clear
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clickedRow)
        table.doubleAction = #selector(doubleClick)
        table.rowMenu = { [weak self] row in self?.menu(row) }
        table.onReturn = { [weak self] in
            guard let self, self.table.selectedRow >= 0 else { return }
            self.activate(self.table.selectedRow, fromKeyboard: false)
        }
        table.onExpand = { [weak self] change in
            guard let self else { return false }
            return self.changeGroup(self.table.selectedRow, change)
        }
        table.setAccessibilityLabel(String(localized: "Repositories and references"))
        filter.placeholderString = String(localized: "Filter")
        filter.controlSize = .small
        filter.font = Theme.body
        filter.delegate = self
        filter.target = self
        filter.action = #selector(filterChanged)
        filter.sendsSearchStringImmediately = true
        filter.setAccessibilityLabel(String(localized: "Filter branches, tags and stashes"))
        filter.setAccessibilityIdentifier("sidebar.filter")
    }

    private func layoutViews() {
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.contentInsets = NSEdgeInsets(top: Metrics.listInset, left: 0, bottom: Metrics.listInset, right: 0)
        // Fork's place for it: on top, above everything it filters.
        for view in [filter, scroll] {
            addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            filter.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.filterInset),
            filter.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.filterInset),
            filter.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.filterTop),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: filter.bottomAnchor, constant: Metrics.listGap),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.sidebar.setFill()
        dirtyRect.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: Scrolling

    /// Vertical scroll position of the list.
    var scrollOffset: CGFloat {
        get { table.enclosingScrollView?.contentView.bounds.origin.y ?? 0 }
        set {
            guard let scroll = table.enclosingScrollView else { return }
            layoutSubtreeIfNeeded()
            let maximum = max(
                -scroll.contentInsets.top,
                table.frame.height - scroll.contentView.bounds.height + scroll.contentInsets.bottom)
            scroll.contentView.scroll(
                to: NSPoint(
                    x: scroll.contentView.bounds.origin.x, y: min(max(newValue, -scroll.contentInsets.top), maximum)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    /// The scroll position a tab switch carries over, measured from the Repositories header (below this tab's own
    /// items, whose length differs per repository): a repository or checkout clicked in Repositories stays under the
    /// pointer. Any other switch made at the top of the list keeps the new tab at its top (`-greatestFiniteMagnitude`).
    var repositoriesScroll: CGFloat {
        get {
            guard let scroll = table.enclosingScrollView,
                openedFromRepositories || scrollOffset > -scroll.contentInsets.top + 0.5
            else { return -.greatestFiniteMagnitude }
            return scrollOffset - repositoriesHeaderY
        }
        set {
            openedFromRepositories = false
            scrollOffset = newValue == -.greatestFiniteMagnitude ? newValue : repositoriesHeaderY + newValue
        }
    }

    /// The last click opened a repository or checkout from the Repositories section.
    private(set) var openedFromRepositories = false
    /// The open checkout's row in Repositories holds the highlight instead of All Commits: it was the row clicked (in
    /// this tab or, carried over by the switch, in the previous one), so the highlight stays where the pointer is.
    /// Any other choice in the sidebar hands it back to the page shown.
    var highlightsOpenCheckout = false {
        didSet { if highlightsOpenCheckout != oldValue, !rows.isEmpty { rebuild() } }
    }
    private var repositoriesHeaderY: CGFloat {
        layoutSubtreeIfNeeded()
        let index = rows.firstIndex(of: .divider).map { $0 + 1 } ?? 0
        return rows.indices.contains(index) ? table.rect(ofRow: index).minY : 0
    }

    // MARK: Rows

    func update(_ next: Input) {
        guard next != input || rows.isEmpty else { return }
        input = next
        rebuild()
    }

    private var query: String { filter.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func rebuild() {
        let next = SidebarRowBuilder(
            input: input, query: query, repositoryExpansion: state.repositoryExpansion,
            groupExpansion: state.groupExpansion, order: state.repositoryOrder,
            key: { WindowAgents.key($0) }
        ).rows()
        let clip = table.enclosingScrollView?.contentView
        let origin = clip?.bounds.origin
        updating = true
        defer { updating = false }
        let previous = rows
        // A group the arrow keys stopped on keeps the keyboard there while it opens and closes.
        let focusedGroup = previous.indices.contains(table.selectedRow) ? previous[table.selectedRow].group?.id : nil
        rows = next
        reload(from: previous)
        if let focusedGroup, let row = rows.firstIndex(where: { $0.group?.id == focusedGroup }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else if let selected = highlightedRow() {
            table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        if let origin, let clip {
            clip.scroll(to: origin)
            table.enclosingScrollView?.reflectScrolledClipView(clip)
        }
    }

    /// The row the highlight belongs on: the page or item shown, or the open checkout when it was the row clicked.
    private func highlightedRow() -> Int? {
        if highlightsOpenCheckout, input.selection == .history,
            let checkout = rows.firstIndex(where: { if case .checkout(_, _, true) = $0 { true } else { false } })
        {
            return checkout
        }
        return rows.firstIndex(where: \.isSelected)
    }

    /// Agent state, counts and selection change far more often than the list's shape: when every row keeps its kind
    /// (and so its height), only the rows whose content changed reload.
    private func reload(from previous: [Row]) {
        guard previous.count == rows.count, zip(previous, rows).allSatisfy({ $0.kind == $1.kind }) else {
            table.reloadData()
            return
        }
        let changed = IndexSet(rows.indices.filter { previous[$0] != rows[$0] })
        if !changed.isEmpty { table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0)) }
        // A checkout row grows a second line when an agent starts there (and loses it when the agent goes): the
        // table keeps the old height unless told, and the agent's line is cut off.
        let resized = IndexSet(changed.filter { previous[$0].height != rows[$0].height })
        guard !resized.isEmpty else { return }
        NSAnimationContext.runAnimationGroup {
            $0.duration = 0
            table.noteHeightOfRows(withIndexesChanged: resized)
        }
    }

    // MARK: Table

    func numberOfRows(in _: NSTableView) -> Int { rows.count }
    func tableView(_: NSTableView, heightOfRow row: Int) -> CGFloat { rows[row].height }
    /// A click selects only rows that open something; the arrow keys also stop on groups, to open and close them.
    func tableView(_: NSTableView, shouldSelectRow row: Int) -> Bool {
        rows[row].isSelectable || (rows[row].group != nil && currentEventType() == .keyDown)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow _: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("sidebar.row")
        return tableView.makeView(withIdentifier: id, owner: nil) as? DeckTableRowView
            ?? {
                let view = DeckTableRowView()
                view.identifier = id
                return view
            }()
    }

    func tableView(_ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("sidebar.cell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? SidebarCell ?? SidebarCell()
        cell.identifier = id
        cell.configure(rows[row])
        cell.sortMenu = { [weak self] in self?.repositoryOrderMenu() }
        cell.onPress = rows[row].group.map { group in
            { [weak self] in
                guard let self, let row = self.rows.firstIndex(where: { $0.group?.id == group.id }) else { return }
                self.changeGroup(row, .toggle)
            }
        }
        if case .reference(let reference) = rows[row] {
            cell.onFilter = { [weak self] kind in self?.onFilter?(reference.reference, kind) }
        } else {
            cell.onFilter = nil
        }
        return cell
    }

    func tableViewSelectionDidChange(_: Notification) {
        guard !updating, table.selectedRow >= 0, currentEventType() == .keyDown else { return }
        activate(table.selectedRow, fromKeyboard: true)
    }

    /// The sort button's menu: Name · Recently Opened · Status, the current one checked.
    func repositoryOrderMenu() -> NSMenu {
        let menu = NSMenu()
        for (order, title) in [
            (RepositoryListOrder.name, String(localized: "Sort by Name")),
            (.recent, String(localized: "Sort by Recently Opened")),
            (.status, String(localized: "Sort by Status")),
        ] {
            // Every sidebar, this one included, re-sorts on the change notification.
            let item = MenuAction(title) { [state] in state.setRepositoryOrder(order) }
            item.state = order == state.repositoryOrder ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    // MARK: Clicks

    @objc private func clickedRow() { click(table.clickedRow) }

    /// A click on `row`: a repository with one checkout opens it; one with several expands or collapses. A checkout
    /// is only selected (a double click or Return opens it). Any other row opens.
    func click(_ row: Int) {
        guard rows.indices.contains(row) else { return }
        switch rows[row] {
        case .repository(let repository, let expanded):
            if !openSoleCheckout(repository, fromKeyboard: false) { toggle(repository, expanded: expanded) }
        case .checkout: break
        default: activate(row, fromKeyboard: false)
        }
    }

    private func toggle(_ repository: Repository, expanded: Bool) {
        state.repositoryExpansion[repository.root.path] = !expanded
        rebuild()
    }

    /// Opens a repository's only checkout, expanding the row when it was closed, so the repository shows without a
    /// second click on the checkout. False when it lists several: the row still only expands and collapses.
    private func openSoleCheckout(_ repository: Repository, fromKeyboard: Bool) -> Bool {
        guard let checkout = repository.soleCheckout else { return false }
        if state.repositoryExpansion[repository.root.path] == false {
            state.repositoryExpansion[repository.root.path] = true
            rebuild()
        }
        let url = URL(fileURLWithPath: checkout.path, isDirectory: true)
        if WindowAgents.key(input.currentRoot) == WindowAgents.key(url) {
            openedFromRepositories = !fromKeyboard
            highlightsOpenCheckout = true
        }
        onOpenCheckout?(url)
        return true
    }

    /// AppKit sends the second of two quick clicks here instead of to `click`: a checkout opens. A repository with
    /// one checkout already opened on the first click. On a row that expands and collapses (a group, a remote, a
    /// repository with several checkouts) it is one more toggle, so fast clicks never get lost. Other rows already
    /// opened on the first click.
    @objc private func doubleClick() { secondClick(table.clickedRow) }

    func secondClick(_ row: Int) {
        guard rows.indices.contains(row) else { return }
        switch rows[row] {
        case .checkout: activate(row, fromKeyboard: false)
        case .repository(let repository, _):
            if repository.soleCheckout == nil { click(row) }
        case .remote, .folder: click(row)
        case .nav(let nav) where nav.expansion != .none: click(row)
        default: break
        }
    }

    func activate(_ row: Int, fromKeyboard: Bool) {
        guard rows.indices.contains(row) else { return }
        // Several checkouts: the row only opens and closes (Return toggles it too). One checkout opens it, including
        // when the selection lands on the row.
        if case .repository(let repository, let expanded) = rows[row] {
            if !openSoleCheckout(repository, fromKeyboard: fromKeyboard), !fromKeyboard {
                toggle(repository, expanded: expanded)
            }
            return
        }
        if case .checkout = rows[row] { openedFromRepositories = !fromKeyboard } else { openedFromRepositories = false }
        highlightsOpenCheckout = openedFromRepositories
        switch rows[row] {
        case .checkout(let checkout, _, _):
            guard !fromKeyboard else { return }
            onOpenCheckout?(URL(fileURLWithPath: checkout.path, isDirectory: true))
        case .nav(let nav):
            if case .page(let page) = nav.target { onNavigate?(page) }
        case .reference(let reference): onReference?(reference.reference)
        case .stash(let stash, _): onStash?(stash)
        default: break
        }
        // A click or Return toggles a group; arrowing onto one leaves it as it is (Left, Right and Space open and
        // close it then, through `SidebarTable.onExpand`).
        if rows[row].group != nil, !fromKeyboard { changeGroup(row, .toggle) }
    }

    /// Opens, closes or toggles the group on `row`; false when the row is not a group.
    @discardableResult
    func changeGroup(_ row: Int, _ change: SidebarTable.GroupChange) -> Bool {
        guard rows.indices.contains(row), let group = rows[row].group else { return false }
        let next =
            switch change {
            case .open: true
            case .close: false
            case .toggle: !group.expanded
            }
        guard next != group.expanded else { return true }
        state.setExpanded(group.id, next)
        rebuild()
        return true
    }

    func menu(_ row: Int) -> NSMenu? {
        guard rows.indices.contains(row) else { return nil }
        switch rows[row] {
        case .reference(let reference): return referenceMenu?(reference.reference)
        case .checkout(let checkout, _, _): return checkoutMenu?(checkout.path, checkout.isMain)
        case .repository(let repository, _):
            return repositoryMenu?(repository) ?? checkoutMenu?(repository.root.path, true)
        case .remote(let name, _, _, _): return remoteMenu?(name)
        case .nav(let nav) where nav.target == .group(.remotes): return remoteMenu?(nil)
        default: return nil
        }
    }

    func controlTextDidChange(_: Notification) { filterChanged() }

    /// Each keystroke shows the list from the top, where the matches are.
    @objc func filterChanged() {
        guard query != lastQuery else { return }
        lastQuery = query
        rebuild()
        scrollOffset = -.greatestFiniteMagnitude
    }
}
