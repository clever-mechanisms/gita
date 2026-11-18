import AppKit
import GitaCore

/// The review window's sidebar: Conversation, then every changed file with its line counts, open threads and the
/// draft's comments on it.
@MainActor
final class ReviewSidebarView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private static let cellID = NSUserInterfaceItemIdentifier("reviewSidebar")
    let table = NSTableView()
    private(set) var rows: [PullRequestReviewState.SidebarRow] = []
    var onSelect: ((PullRequestReviewState.Page) -> Void)?
    private var isUpdating = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row")))
        table.headerView = nil
        table.rowHeight = 26
        table.style = .sourceList
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel(String(localized: "Pull request files"))
        Style.fill(Style.scroll(table), in: self)
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("ReviewSidebarView is built in code") }

    func update(_ rows: [PullRequestReviewState.SidebarRow], selected: PullRequestReviewState.Page) {
        isUpdating = true
        defer { isUpdating = false }
        if rows != self.rows {
            self.rows = rows
            table.reloadData()
        }
        if let index = rows.firstIndex(where: { $0.page == selected }), table.selectedRow != index {
            table.selectRowIndexes([index], byExtendingSelection: false)
        }
    }

    func numberOfRows(in _: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        let cell =
            tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? ReviewSidebarCell ?? ReviewSidebarCell()
        cell.identifier = Self.cellID
        cell.show(rows[row])
        return cell
    }

    func tableViewSelectionDidChange(_: Notification) {
        guard !isUpdating, rows.indices.contains(table.selectedRow) else { return }
        onSelect?(rows[table.selectedRow].page)
    }
}

/// One sidebar row: an icon, the file name with its folder, the line counts and the discussion badges.
@MainActor
final class ReviewSidebarCell: NSTableCellView {
    private let icon = NSImageView()
    private let name = Deck.label("", font: Theme.body)
    private let folder = Deck.caption("")
    private let detail = Deck.caption("")
    private let badges = Deck.caption("")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
        // Six files named page.tsx read apart by their folders, cut from the left: the nearest folder stays.
        folder.lineBreakMode = .byTruncatingHead
        folder.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        icon.widthAnchor.constraint(equalToConstant: 14).isActive = true
        let row = Deck.hstack([icon, name, folder, Deck.spacer(), badges, detail], spacing: 6)
        row.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 6)
        Deck.pin(row, in: self)
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("ReviewSidebarCell is built in code") }

    func show(_ row: PullRequestReviewState.SidebarRow) {
        let isConversation = row.page == .conversation
        let symbol = isConversation ? "bubble.left.and.bubble.right" : "doc.text"
        icon.setSymbol(symbol, size: 11, color: Theme.secondaryText)
        name.stringValue = isConversation ? row.title : URL(fileURLWithPath: row.title).lastPathComponent
        name.font = isConversation ? Theme.bodyEmphasis : Theme.body
        folder.stringValue = isConversation ? "" : ReviewSidebarFacts.folder(row.title)
        toolTip = row.title
        detail.stringValue = row.detail
        badges.stringValue = ReviewSidebarFacts.badges(row)
        badges.textColor = row.pendingCount > 0 ? Theme.running : Theme.secondaryText
        let parts = [row.title, row.detail, badges.stringValue].filter { !$0.isEmpty }
        setAccessibilityLabel(parts.joined(separator: ", "))
    }
}

enum ReviewSidebarFacts {
    /// The folder the file is in ("guides" for app/[locale]/guides/page.tsx), empty at the top level; the row's
    /// tooltip has the whole path.
    static func folder(_ path: String) -> String {
        let parts = path.split(separator: "/")
        return parts.count > 1 ? String(parts[parts.count - 2]) : ""
    }

    /// "💬 2 · ✎ 1": open discussions, then the draft's line comments.
    static func badges(_ row: PullRequestReviewState.SidebarRow) -> String {
        var parts: [String] = []
        if row.discussionCount > 0 { parts.append("💬 \(row.discussionCount)") }
        if row.pendingCount > 0 { parts.append("✎ \(row.pendingCount)") }
        return parts.joined(separator: " · ")
    }
}
