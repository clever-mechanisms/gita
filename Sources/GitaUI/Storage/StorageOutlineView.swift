import AppKit
import GitaCore

@MainActor
final class StorageOutlineView: NSScrollView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private final class Item: NSObject {
        let node: StorageOutlineNode
        let children: [Item]

        init(_ node: StorageOutlineNode) {
            self.node = node
            children = node.children.map(Self.init)
        }
    }

    private let outline = NSOutlineView()
    private var roots = [Item]()
    private(set) var checked = Set<String>()
    var onSelectionChanged: ((Set<String>) -> Void)?
    var onTrash: ((HeavyFolderEntry) -> Void)?
    var onRemove: ((CheckoutStorageReport) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        hasVerticalScroller = true
        drawsBackground = false
        let name = NSTableColumn(identifier: .init("folder"))
        name.title = String(localized: "Folder")
        name.minWidth = 280
        let bytes = NSTableColumn(identifier: .init("bytes"))
        bytes.title = String(localized: "Allocated size")
        bytes.width = 108
        bytes.resizingMask = []
        outline.addTableColumn(name)
        outline.addTableColumn(bytes)
        outline.outlineTableColumn = name
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        outline.rowHeight = 29
        outline.backgroundColor = Theme.window
        outline.menu = NSMenu()
        outline.menu?.delegate = self
        documentView = outline
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("StorageOutlineView is built in code") }

    func display(_ nodes: [StorageOutlineNode]) {
        let expanded = Set(roots.filter { outline.isItemExpanded($0) }.map { $0.node.url.path })
        let fresh = roots.isEmpty
        roots = nodes.map(Item.init)
        checked.formIntersection(nodes.flatMap(\.children).filter(\.isSelectable).map { $0.url.path })
        outline.reloadData()
        for root in roots where expanded.contains(root.node.url.path) || (fresh && root.node.checkout != nil) {
            outline.expandItem(root)
        }
    }

    func outlineView(_: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Item)?.children.count ?? roots.count
    }

    func outlineView(_: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? Item)?.children ?? roots)[index]
    }

    func outlineView(_: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? Item)?.children.isEmpty == false
    }

    func outlineView(_: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = (item as? Item)?.node else { return nil }
        if tableColumn?.identifier.rawValue == "bytes" {
            let size = Deck.label(StoragePresenter().formatBytes(node.bytes), font: Theme.mono)
            size.alignment = .right
            return size
        }
        var parts = [NSView]()
        if node.isSelectable {
            let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggle(_:)))
            box.identifier = .init(node.url.path)
            box.setAccessibilityLabel(String(localized: "Select \(node.title) for cleanup"))
            box.state = checked.contains(node.url.path) ? .on : .off
            parts.append(box)
        }
        parts.append(Deck.label(node.title))
        if let branch = node.branch {
            parts.append(StorageSummaryBar.badge(branch, fill: Deck.pillColors(.branch).fill))
        }
        if let caption = node.caption { parts.append(Deck.caption(caption)) }
        if let warning = node.warning {
            let icon = Deck.icon("exclamationmark.triangle.fill", size: 13, color: Theme.needsInputText)
            icon.toolTip = warning
            icon.setAccessibilityLabel(warning)
            parts.append(icon)
        }
        let row = Deck.hstack(parts)
        row.toolTip = node.url.path
        return row
    }

    @objc private func toggle(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        if sender.state == .on { checked.insert(path) } else { checked.remove(path) }
        onSelectionChanged?(checked)
    }
}

extension StorageOutlineView: NSMenuDelegate {
    private var contextNode: StorageOutlineNode? {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        guard row >= 0 else { return nil }
        return (outline.item(atRow: row) as? Item)?.node
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let node = contextNode else { return }
        func item(_ title: String, _ selector: Selector) {
            menu.addItem(withTitle: title, action: selector, keyEquivalent: "").target = self
        }
        item(String(localized: "Reveal in Finder"), #selector(reveal))
        if node.isSelectable { item(String(localized: "Move to Trash…"), #selector(trash)) }
        if let tree = node.checkout, !tree.isMainWorktree && !tree.isBare && !tree.isLocked {
            item(String(localized: "Remove Worktree…"), #selector(removeTree))
        }
    }

    @objc private func reveal() { if let node = contextNode { OpenIn.finder(node.url) } }
    @objc private func trash() { if let entry = contextNode?.entry { onTrash?(entry) } }
    @objc private func removeTree() { if let tree = contextNode?.checkout { onRemove?(tree) } }
}
