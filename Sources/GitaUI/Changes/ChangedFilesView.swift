import AppKit
import GitaCore

/// Changed files: a folder tree (or a flat list) with a status badge per file (M, +, −, R, !), the file's own icon,
/// multiple selection, a context menu and a filter. Used for Unstaged and Staged in Local Changes and for a commit's
/// or stash's files in History.
@MainActor
final class ChangedFilesView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    typealias Side = ChangedFileSide
    private enum Metrics {
        static let rowHeight: CGFloat = 22
        static let indentation: CGFloat = 14
        static let emptyInset: CGFloat = 20
    }
    private static let rowID = NSUserInterfaceItemIdentifier("files.row")
    private static let cellID = NSUserInterfaceItemIdentifier("files.cell")

    let side: Side
    let outline = FileOutline()
    private let empty = Deck.caption("")
    private var files: [FileChange] = []
    private var roots: [ChangedFileNode] = []
    private var nodesByPath: [String: ChangedFileNode] = [:]
    /// Folders the user closed; every other folder opens when the list is rebuilt.
    private var collapsed: Set<String> = []
    private var updating = false
    /// Above this many files the list stays flat: a tree of tens of thousands of rows is slower to open than to read.
    static let treeLimit = 5_000
    var query = "" { didSet { if query != oldValue { rebuild() } } }
    var showsTree = true { didSet { if showsTree != oldValue { rebuild() } } }
    var emptyText = "" { didSet { updateEmpty() } }
    /// A file chosen by click or keyboard (not by `select(path:)`).
    var onSelect: ((FileChange) -> Void)?
    /// Double-click or Return on a file.
    var onActivate: ((FileChange) -> Void)?
    /// The selection changed in any way (enables the section's Stage / Unstage button).
    var onSelectionChange: (() -> Void)?
    /// The context menu for the files under the click (the clicked one joins the selection first, as in Finder).
    var menuProvider: (([FileChange]) -> NSMenu?)?
    /// The list took keyboard focus or a click (the other section lets go of its selection).
    var onFocus: (() -> Void)?

    init(side: Side) {
        self.side = side
        super.init(frame: .zero)
        configureOutline()
        let scroll = Style.scroll(outline)
        scroll.drawsBackground = false
        Style.fill(scroll, in: self)
        addSubview(empty)
        empty.translatesAutoresizingMaskIntoConstraints = false
        empty.alignment = .center
        NSLayoutConstraint.activate([
            empty.centerXAnchor.constraint(equalTo: centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -Metrics.emptyInset),
        ])
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("ChangedFilesView is built in code") }

    private func configureOutline() {
        let column = NSTableColumn(identifier: .init("file"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = Metrics.rowHeight
        outline.intercellSpacing = .zero
        outline.indentationPerLevel = Metrics.indentation
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outline.allowsMultipleSelection = true
        outline.allowsEmptySelection = true
        outline.autoresizesOutlineColumn = false
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(doubleClick)
        outline.rowMenu = { [weak self] rows in self?.menu(for: rows) }
        outline.onReturn = { [weak self] in self?.activateSelection() }
        outline.onFocus = { [weak self] in self?.onFocus?() }
    }

    /// Shows `next`; keeps open folders, the selection and the scroll position when only some files changed.
    func update(_ next: [FileChange]) {
        guard next != files else { return }
        files = next
        rebuild()
    }
    var isTree: Bool { showsTree && files.count <= Self.treeLimit }
    var selectedFiles: [FileChange] {
        outline.selectedRowIndexes.compactMap { outline.item(atRow: $0) as? ChangedFileNode }.flatMap(\.files)
            .uniqued()
    }
    /// Highlights the file at `path` (nil clears), without calling `onSelect`.
    func select(path: String?) {
        updating = true
        defer { updating = false }
        guard let path, let node = nodesByPath[path], !node.isFolder else {
            if outline.selectedRow >= 0 {
                outline.deselectAll(nil)
                onSelectionChange?()
            }
            return
        }
        // Already part of the selection (a multiple selection that includes it stays).
        if outline.selectedRowIndexes.contains(outline.row(forItem: node)) { return }
        reveal(node)
        let row = outline.row(forItem: node)
        guard row >= 0 else { return }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.scrollRowToVisible(row)
        onSelectionChange?()
    }
    func expandAll() {
        collapsed = []
        updating = true
        outline.expandItem(nil, expandChildren: true)
        updating = false
    }
    func collapseAll() {
        updating = true
        defer { updating = false }
        for node in roots where !node.children.isEmpty { outline.collapseItem(node, collapseChildren: true) }
        collapsed = Set(nodesByPath.values.filter(\.isFolder).map(\.path))
    }
    /// Every folder is closed (the collapse button then offers to open them).
    var isCollapsed: Bool {
        isTree && roots.contains(where: \.isFolder) && roots.allSatisfy { !$0.isFolder || !outline.isItemExpanded($0) }
    }

    private func menu(for rows: IndexSet) -> NSMenu? {
        let files = rows.compactMap { outline.item(atRow: $0) as? ChangedFileNode }.flatMap(\.files)
        return files.isEmpty ? nil : menuProvider?(files)
    }
    private func activateSelection() {
        if let file = selectedFiles.first { onActivate?(file) }
    }
    private func reveal(_ node: ChangedFileNode) {
        var chain: [ChangedFileNode] = []
        var parent = outline.parent(forItem: node) as? ChangedFileNode
        while let folder = parent {
            chain.insert(folder, at: 0)
            parent = outline.parent(forItem: folder) as? ChangedFileNode
        }
        for folder in chain where !outline.isItemExpanded(folder) {
            collapsed.remove(folder.path)
            outline.expandItem(folder)
        }
    }

    private func rebuild() {
        let selected = Set(selectedFiles.map(\.path))
        let origin = outline.enclosingScrollView?.contentView.bounds.origin
        let filtering = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let shown = ChangedFileTree.filter(files, query: query)
        nodesByPath = [:]
        roots =
            isTree ? ChangedFileTree.tree(shown, index: &nodesByPath) : ChangedFileTree.flat(shown, index: &nodesByPath)
        updating = true
        outline.reloadData()
        // A filter opens every folder that holds a match.
        if isTree { open(roots, all: filtering) }
        let rows = IndexSet(selected.compactMap { nodesByPath[$0] }.map { outline.row(forItem: $0) }.filter { $0 >= 0 })
        outline.selectRowIndexes(rows, byExtendingSelection: false)
        if let origin, let scroll = outline.enclosingScrollView {
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        updating = false
        updateEmpty()
        onSelectionChange?()
    }
    private func open(_ nodes: [ChangedFileNode], all: Bool) {
        for node in nodes where node.isFolder && (all || !collapsed.contains(node.path)) {
            outline.expandItem(node)
            open(node.children, all: all)
        }
    }
    private func updateEmpty() {
        let filtered = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !files.isEmpty
        empty.stringValue = filtered ? String(localized: "No matching files") : emptyText
        empty.isHidden = !roots.isEmpty || empty.stringValue.isEmpty
    }

    /// The badge letter and colour for a file on this side (M yellow, + green, − red, R blue, ! conflict).
    func status(_ file: FileChange) -> (letter: String, color: NSColor, spoken: String) {
        let status = ChangedFileStatus(file, side: side)
        return (status.letter, Self.color(status.kind), status.spoken)
    }
    static func color(_ kind: ChangedFileStatus.Kind) -> NSColor {
        switch kind {
        case .conflict, .deleted: Theme.failure
        case .added: Theme.success
        case .renamed, .copied: Theme.running
        case .typeChanged: Theme.merged
        case .modified: Theme.needsInput
        }
    }

    // MARK: Outline

    func outlineView(_: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? ChangedFileNode)?.children.count ?? roots.count
    }
    func outlineView(_: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? ChangedFileNode)?.children[index] ?? roots[index]
    }
    func outlineView(_: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? ChangedFileNode)?.isFolder ?? false
    }
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem _: Any) -> NSTableRowView? {
        DeckTableRowView.reused(in: outlineView, id: Self.rowID)
    }
    func outlineView(_ outlineView: NSOutlineView, viewFor _: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? ChangedFileNode else { return nil }
        let cell =
            outlineView.makeView(withIdentifier: Self.cellID, owner: nil) as? ChangedFileCell ?? ChangedFileCell()
        cell.identifier = Self.cellID
        guard let file = node.file else {
            cell.configure(name: node.name, detail: nil, icon: FileIcons.folder, badge: nil, color: nil)
            cell.toolTip = node.path
            cell.setAccessibilityLabel(node.name)
            return cell
        }
        let status = status(file)
        let folder = RepositoryPathText.folder(file.path)
        cell.configure(
            name: node.name, detail: isTree || folder.isEmpty ? nil : folder, icon: FileIcons.icon(for: file.path),
            badge: status.letter, color: status.color)
        cell.toolTip = file.originalPath.map { $0 + " → " + file.path } ?? file.path
        cell.setAccessibilityLabel([file.path, status.spoken].joined(separator: ", "))
        return cell
    }
    func outlineViewItemDidCollapse(_ notification: Notification) {
        if !updating, let node = notification.userInfo?["NSObject"] as? ChangedFileNode { collapsed.insert(node.path) }
    }
    func outlineViewItemDidExpand(_ notification: Notification) {
        if !updating, let node = notification.userInfo?["NSObject"] as? ChangedFileNode { collapsed.remove(node.path) }
    }
    func outlineViewSelectionDidChange(_: Notification) {
        guard !updating else { return }
        onSelectionChange?()
        // The row last clicked is the one the diff shows; after a keyboard move, the row moved to.
        let clicked = outline.mouseRow.flatMap { outline.selectedRowIndexes.contains($0) ? $0 : nil }
        let row = clicked ?? outline.selectedRow
        if !outline.selectedRowIndexes.isEmpty, let file = (outline.item(atRow: row) as? ChangedFileNode)?.file {
            onSelect?(file)
        }
    }
    @objc private func doubleClick() {
        let row = outline.clickedRow
        guard row >= 0, let file = (outline.item(atRow: row) as? ChangedFileNode)?.file else { return }
        onActivate?(file)
    }
}

extension Array where Element: Hashable {
    fileprivate func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
