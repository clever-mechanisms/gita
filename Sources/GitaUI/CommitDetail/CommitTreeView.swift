import AppKit
import GitaCore

/// A commit's files as a tree. Fetches one Git tree at a time; collapsed subtrees have no nodes or process work.
@MainActor
final class CommitTreeView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private final class Node: NSObject {
        let entry: TreeEntry
        /// Loaded with the folder's first expansion.
        var children: [Node] = []
        var isLoaded = false
        init(_ entry: TreeEntry) { self.entry = entry }
        var kind: CommitTreeOrder.Kind { CommitTreeOrder.Kind(entry) }
    }
    private enum Metrics {
        static let rowHeight: CGFloat = 26
        static let indentation: CGFloat = 13
        static let iconSide: CGFloat = 14
        static let iconLeading: CGFloat = 2
        static let labelGap: CGFloat = 6
        static let trailing: CGFloat = 4
        static let emptyInset: CGFloat = 20
    }
    private static let cellID = NSUserInterfaceItemIdentifier("treeCell")

    let outline = FileOutline()
    private let empty = Style.label(String(localized: "Select a commit"), size: 11, color: .secondaryLabelColor)
    private var roots: [Node] = []
    private(set) var rootLoad = CommitTreeRootLoad.noCommit
    private var service: GitService?
    private var commit: String?
    private var generation = 0
    private(set) var tasks: [String: Task<Void, Never>] = [:]
    var onSelect: ((TreeEntry) -> Void)?
    var onError: ((String) -> Void)?
    /// The context menu for a file or folder.
    var menuProvider: ((TreeEntry) -> NSMenu?)?
    /// The folders to open and the path to select once they are loaded (Show in File Tree).
    private(set) var pendingReveal = CommitTreeReveal()

    override init(frame: NSRect) {
        super.init(frame: frame)
        let column = NSTableColumn(identifier: .init("tree"))
        column.title = String(localized: "Files")
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = Metrics.rowHeight
        outline.intercellSpacing = .zero
        outline.indentationPerLevel = Metrics.indentation
        outline.dataSource = self
        outline.delegate = self
        outline.style = .plain
        outline.setAccessibilityLabel(String(localized: "Commit file tree"))
        outline.rowMenu = { [weak self] rows in self?.menu(for: rows) }
        Style.fill(Style.scroll(outline), in: self)
        addSubview(empty)
        empty.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            empty.centerXAnchor.constraint(equalTo: centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -Metrics.emptyInset),
        ])
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("CommitTreeView is built in code") }

    private func menu(for rows: IndexSet) -> NSMenu? {
        guard rows.count == 1, let row = rows.first, let node = outline.item(atRow: row) as? Node else { return nil }
        return menuProvider?(node.entry)
    }

    func configure(service: GitService?, commit: String?) {
        guard self.service !== service || self.commit != commit else { return }
        generation += 1
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        self.service = service
        self.commit = commit
        roots = []
        // A walk asked for in the previous commit's tree never continues in this one.
        pendingReveal.end()
        outline.reloadData()
        showRootLoad(CommitTreeRootLoad(commit: commit))
        if commit != nil { load(nil) }
    }
    private func showRootLoad(_ next: CommitTreeRootLoad) {
        rootLoad = next
        empty.stringValue = next.placeholder ?? empty.stringValue
        empty.isHidden = next.placeholder == nil
    }
    private func load(_ node: Node?) {
        guard let service, let commit else { return }
        let path = node?.entry.path ?? ""
        let token = generation
        guard tasks[path] == nil else { return }
        tasks[path] = Task { [weak self, weak node] in
            do {
                let entries = try await service.tree(commit: commit, path: path)
                let sorting = Task.detached(priority: .userInitiated) { CommitTreeOrder.sorted(entries) }
                let sorted = await withTaskCancellationHandler {
                    await sorting.value
                } onCancel: {
                    sorting.cancel()
                }
                guard let self, !Task.isCancelled, token == self.generation else { return }
                self.loaded(sorted.map(Node.init), into: node, path: path)
            } catch {
                guard let self, !Task.isCancelled, token == self.generation else { return }
                self.failed(error, node: node, path: path)
            }
        }
    }
    private func loaded(_ nodes: [Node], into node: Node?, path: String) {
        if let node {
            node.children = nodes
            node.isLoaded = true
            outline.reloadItem(node, reloadChildren: true)
        } else {
            roots = nodes
            outline.reloadData()
            showRootLoad(.loaded(isEmpty: nodes.isEmpty))
        }
        tasks[path] = nil
        continueReveal()
    }
    private func failed(_ error: Error, node: Node?, path: String) {
        tasks[path] = nil
        if node == nil { showRootLoad(.failed) }
        pendingReveal.failed(folder: path)
        onError?(error.localizedDescription)
    }

    /// Opens the folders down to `path` (loading each one as needed) and selects it.
    func reveal(_ path: String) {
        pendingReveal.request(path)
        continueReveal()
    }
    private func continueReveal() {
        guard let path = pendingReveal.path, rootLoad == .loaded(isEmpty: false) else { return }
        var level = roots
        for prefix in CommitTreeOrder.pathPrefixes(path) {
            guard let node = level.first(where: { $0.entry.path == prefix }) else { break }
            if prefix == path {
                pendingReveal.end()
                select(node)
                return
            }
            // Expanding loads the folder; the load picks the walk up again.
            outline.expandItem(node)
            guard node.isLoaded else { return }
            level = node.children
        }
        pendingReveal.end()
    }
    private func select(_ node: Node) {
        let row = outline.row(forItem: node)
        if row >= 0 {
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        }
        window?.makeFirstResponder(outline)
    }

    func outlineView(_: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else { return roots.count }
        return (item as? Node)?.children.count ?? 0
    }
    func outlineView(_: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? Node else { return roots[index] }
        return node.children[index]
    }
    func outlineView(_: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? Node)?.kind == .folder
    }
    func outlineView(_: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        if let node = item as? Node, !node.isLoaded { load(node) }
        return true
    }
    func outlineView(_ outlineView: NSOutlineView, viewFor _: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? Node else { return nil }
        let cell = outlineView.makeView(withIdentifier: Self.cellID, owner: nil) as? NSTableCellView ?? Self.makeCell()
        let kind = node.kind
        cell.textField?.stringValue = RepositoryPathText.name(node.entry.path)
        cell.imageView?.image = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil)
        cell.imageView?.contentTintColor = kind == .folder ? .systemBlue : .secondaryLabelColor
        cell.toolTip = node.entry.path
        return cell
    }
    private static func makeCell() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = cellID
        let icon = NSImageView()
        let label = Style.label("")
        cell.imageView = icon
        cell.textField = label
        for view in [icon, label] {
            cell.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Metrics.iconLeading),
            icon.widthAnchor.constraint(equalToConstant: Metrics.iconSide),
            icon.heightAnchor.constraint(equalToConstant: Metrics.iconSide),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Metrics.labelGap),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -Metrics.trailing),
        ])
        return cell
    }
    func outlineViewSelectionDidChange(_: Notification) {
        if let node = outline.item(atRow: outline.selectedRow) as? Node, node.kind != .folder {
            onSelect?(node.entry)
        }
    }
}
