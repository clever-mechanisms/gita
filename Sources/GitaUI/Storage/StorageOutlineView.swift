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

    private let outline = CenteredOutlineView()
    private let presenter = StoragePresenter()
    private var roots = [Item]()
    private(set) var checked = Set<String>()
    var onSelectionChanged: ((Set<String>) -> Void)?
    var onTrash: ((HeavyFolderEntry) -> Void)?
    var onRemove: ((CheckoutStorageReport) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        hasVerticalScroller = true
        autohidesScrollers = true
        borderType = .noBorder
        drawsBackground = false

        let name = NSTableColumn(identifier: .init("folder"))
        name.title = String(localized: "Folder")
        name.minWidth = 320
        let bytes = NSTableColumn(identifier: .init("bytes"))
        bytes.title = String(localized: "Allocated size")
        bytes.width = 166
        bytes.resizingMask = []
        bytes.headerCell.alignment = .right

        outline.addTableColumn(name)
        outline.addTableColumn(bytes)
        outline.outlineTableColumn = name
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.style = .plain
        outline.intercellSpacing = NSSize(width: 8, height: 0)
        outline.gridStyleMask = .solidHorizontalGridLineMask
        outline.rowHeight = 36
        outline.indentationPerLevel = 18
        outline.backgroundColor = .clear
        outline.dataSource = self
        outline.delegate = self
        outline.menu = NSMenu()
        outline.menu?.delegate = self
        documentView = outline
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("StorageOutlineView is built in code") }

    func applyTheme() {
        outline.gridColor = Theme.separator.withAlphaComponent(0.45)
        outline.needsDisplay = true
    }

    func display(_ nodes: [StorageOutlineNode]) {
        applyTheme()
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
            return makeBytesCell(for: node)
        }
        return makeFolderCell(for: node)
    }

    private func makeBytesCell(for node: StorageOutlineNode) -> NSView {
        let tint = StorageStyle.nodeToneColor(node.tone)
        let bar = StorageStyle.proportionBar(fraction: node.share, tint: tint, width: 56, height: 5)
        let weight: NSFont.Weight = node.isTopLevel ? .medium : .regular
        let color: NSColor = node.isTopLevel ? Theme.text : Theme.secondaryText
        let label = Deck.label(
            presenter.formatBytes(node.bytes),
            font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: weight), color: color)
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(greaterThanOrEqualToConstant: 74).isActive = true
        let row = Deck.hstack([Deck.spacer(), bar, label], spacing: 10)
        return CenteredOutlineCell(content: row, leading: 4, trailing: 12, fillsWidth: true)
    }

    private func makeFolderCell(for node: StorageOutlineNode) -> NSView {
        let row = Deck.hstack([], spacing: 7)
        if node.isSelectable {
            let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggle(_:)))
            box.controlSize = .small
            box.identifier = .init(node.url.path)
            box.setAccessibilityLabel(String(localized: "Select \(node.title) for cleanup"))
            box.state = checked.contains(node.url.path) ? .on : .off
            row.addArrangedSubview(box)
        }
        row.addArrangedSubview(
            StorageStyle.iconBadge(
                node.symbolName, tint: StorageStyle.nodeToneColor(node.tone),
                boxSize: 22, symbolSize: 11, cornerRadius: 5))
        let title = Deck.label(node.title, font: node.isTopLevel ? Theme.bodyEmphasis : Theme.body, color: Theme.text)
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(title)
        appendMetadata(for: node, to: row)
        row.toolTip = node.url.path
        return CenteredOutlineCell(content: row, leading: 2, trailing: 6, fillsWidth: node.entry != nil)
    }

    private func appendMetadata(for node: StorageOutlineNode, to row: NSStackView) {
        if node.kind == .mainCheckout {
            let mainBadge = StorageStyle.pill(
                String(localized: "Main"), fill: Theme.accent.withAlphaComponent(0.14), textColor: Theme.accentText)
            row.addArrangedSubview(mainBadge)
        }
        if let branch = node.branch {
            let colors = Deck.pillColors(.branch)
            let pill = StorageStyle.pill(branch, fill: colors.fill, textColor: colors.text)
            row.addArrangedSubview(pill)
            row.setVisibilityPriority(.detachOnlyIfNecessary, for: pill)
        }
        if let caption = node.caption {
            let label = Deck.caption(caption)
            row.addArrangedSubview(label)
            row.setVisibilityPriority(.detachOnlyIfNecessary, for: label)
        }
        if node.reclaimableBytes > 0 {
            row.addArrangedSubview(StorageStyle.reclaimablePill(node.reclaimableBytes, presenter: presenter))
        }
        if let warning = node.warning {
            let badge = StorageStyle.pill(
                String(localized: "Active Agent"), fill: Theme.running.withAlphaComponent(0.14),
                textColor: Theme.running)
            badge.setAccessibilityElement(true)
            badge.setAccessibilityRole(.staticText)
            badge.setAccessibilityLabel(warning)
            badge.toolTip = warning
            row.addArrangedSubview(badge)
        }
        if let entry = node.entry { appendHeavyFolderControls(for: entry, url: node.url, to: row) }
    }

    private func appendHeavyFolderControls(for entry: HeavyFolderEntry, url: URL, to row: NSStackView) {
        if entry.status == .reclaimable {
            row.addArrangedSubview(StorageStyle.statusPill(String(localized: "Ignored"), tone: .positive))
        } else if entry.status == .trackedOrUnignored {
            row.addArrangedSubview(StorageStyle.statusPill(String(localized: "Protected"), tone: .warning))
        }
        row.addArrangedSubview(Deck.spacer())
        row.addArrangedSubview(
            StorageStyle.iconButton(
                symbol: "folder", accessibility: String(localized: "Reveal in Finder"), tint: Theme.secondaryText
            ) { OpenIn.finder(url) })
        if entry.status == .reclaimable {
            row.addArrangedSubview(
                StorageStyle.iconButton(
                    symbol: "trash", accessibility: String(localized: "Move to Trash…"), tint: Theme.failure
                ) { [weak self] in self?.onTrash?(entry) })
        }
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

/// Outline view that vertically centers disclosure chevrons and stops grid lines after the last populated row.
@MainActor
private final class CenteredOutlineView: NSOutlineView {
    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        var frame = super.frameOfOutlineCell(atRow: row)
        guard !frame.isEmpty else { return frame }
        let rowRect = rect(ofRow: row)
        frame.origin.y = rowRect.origin.y + ((rowRect.height - frame.height) / 2).rounded()
        return frame
    }

    override func drawGrid(inClipRect clipRect: NSRect) {
        guard numberOfRows > 0 else { return }
        let lastRowMaxY = rect(ofRow: numberOfRows - 1).maxY
        let clipped = NSRect(
            x: clipRect.minX, y: clipRect.minY, width: clipRect.width,
            height: max(0, min(clipRect.maxY, lastRowMaxY) - clipRect.minY))
        guard clipped.height > 0 else { return }
        super.drawGrid(inClipRect: clipped)
    }
}

/// Table cell wrapper whose content is strictly vertically centered inside the row.
@MainActor
private final class CenteredOutlineCell: NSTableCellView {
    init(content: NSView, leading: CGFloat, trailing: CGFloat, fillsWidth: Bool) {
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        let trailingConstraint =
            fillsWidth
            ? content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -trailing)
            : content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -trailing)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leading),
            trailingConstraint,
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("CenteredOutlineCell is built in code") }
}
