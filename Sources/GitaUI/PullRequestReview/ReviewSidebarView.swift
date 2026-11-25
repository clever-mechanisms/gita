import AppKit
import GitaCore

/// The review window's sidebar: Conversation, then every changed file with its line counts, open threads and the
/// draft's comments on it.
@MainActor
final class ReviewSidebarView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private static let cellID = NSUserInterfaceItemIdentifier("reviewSidebar")
    let table = NSTableView()
    private let header = Deck.caption("")
    private let headerBar: NSStackView
    private(set) var rows: [PullRequestReviewState.SidebarRow] = []
    var onSelect: ((PullRequestReviewState.Page) -> Void)?
    var onToggleViewed: ((String) -> Void)?
    var isCompact = false {
        didSet {
            guard isCompact != oldValue else { return }
            updateCompactLayout()
        }
    }
    private var isUpdating = false

    override init(frame frameRect: NSRect) {
        headerBar = Deck.hstack([header, Deck.spacer()], spacing: 6)
        super.init(frame: frameRect)
        headerBar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 4, right: 10)
        headerBar.isHidden = true
        header.font = Theme.captionEmphasis
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row")))
        table.headerView = nil
        table.rowHeight = 26
        table.style = .sourceList
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel(String(localized: "Pull request files"))
        let scroll = Style.scroll(table)
        let stack = Deck.vstack([headerBar, scroll], spacing: 0)
        stack.distribution = .fill
        Deck.pin(stack, in: self)
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("ReviewSidebarView is built in code") }

    private var isLoadingFiles = false

    func update(
        _ rows: [PullRequestReviewState.SidebarRow], selected: PullRequestReviewState.Page, viewedCount: Int? = nil,
        isLoadingFiles: Bool = false
    ) {
        isUpdating = true
        defer { isUpdating = false }
        let loadingChanged = self.isLoadingFiles != isLoadingFiles
        self.isLoadingFiles = isLoadingFiles
        if rows != self.rows {
            self.rows = rows
            updateHeader(viewedCount: viewedCount)
            table.reloadData()
        } else if loadingChanged {
            updateHeader(viewedCount: viewedCount)
        }
        if let index = rows.firstIndex(where: { $0.page == selected }), table.selectedRow != index {
            table.selectRowIndexes([index], byExtendingSelection: false)
        }
    }

    private func updateHeader(viewedCount: Int? = nil) {
        let fileRows = rows.filter { if case .file = $0.page { true } else { false } }
        if fileRows.isEmpty, isLoadingFiles {
            header.stringValue = String(localized: "Loading files…")
            headerBar.isHidden = isCompact
            return
        }
        let viewed = viewedCount ?? fileRows.count(where: \.isViewed)
        header.stringValue = fileRows.isEmpty ? "" : String(localized: "Files (\(viewed)/\(fileRows.count) viewed)")
        headerBar.isHidden = isCompact || fileRows.isEmpty
    }

    private func updateCompactLayout() {
        updateHeader()
        table.reloadData()
        if let index = rows.firstIndex(where: { $0.page == selectedPage }), table.selectedRow != index {
            isUpdating = true
            table.selectRowIndexes([index], byExtendingSelection: false)
            isUpdating = false
        }
    }

    private var selectedPage: PullRequestReviewState.Page? {
        rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].page : nil
    }

    func numberOfRows(in _: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        let cell =
            tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? ReviewSidebarCell ?? ReviewSidebarCell()
        cell.identifier = Self.cellID
        let entry = rows[row]
        cell.onToggleViewed = { [weak self] in
            if case .file(let path) = entry.page { self?.onToggleViewed?(path) }
        }
        cell.show(entry, compact: isCompact)
        return cell
    }

    func tableViewSelectionDidChange(_: Notification) {
        guard !isUpdating, rows.indices.contains(table.selectedRow) else { return }
        onSelect?(rows[table.selectedRow].page)
    }
}

/// One sidebar row: an icon (or viewed checkmark), the file name with its folder, the line counts and badges.
@MainActor
final class ReviewSidebarCell: NSTableCellView {
    private let icon = PartsButton([], accessibility: "")
    private let name = Deck.label("", font: Theme.body)
    private let folder = Deck.caption("")
    private let detail = Deck.caption("")
    private let badges = Deck.caption("")
    var onToggleViewed: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
        // Six files named page.tsx read apart by their folders, cut from the left: the nearest folder stays.
        folder.lineBreakMode = .byTruncatingHead
        folder.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        icon.fixedHeight = 16
        icon.horizontalPadding = 2
        icon.cornerRadius = 4
        icon.onClick = { [weak self] in self?.onToggleViewed?() }
        let row = Deck.hstack([icon, name, folder, Deck.spacer(), badges, detail], spacing: 6)
        row.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 6)
        Deck.pin(row, in: self)
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("ReviewSidebarCell is built in code") }

    func show(_ row: PullRequestReviewState.SidebarRow, compact: Bool = false) {
        let isConversation = row.page == .conversation
        let symbol =
            isConversation
            ? "bubble.left.and.bubble.right"
            : (row.isViewed ? "checkmark.square.fill" : "square")
        let iconColor = row.isViewed && !isConversation ? Theme.success : Theme.secondaryText
        icon.parts = [.symbol(symbol, color: iconColor, size: 11)]
        icon.isEnabled = !isConversation
        let viewedTip = row.isViewed ? String(localized: "Viewed") : String(localized: "Mark as viewed")
        icon.toolTip = isConversation ? row.title : viewedTip
        name.isHidden = compact
        folder.isHidden = compact
        detail.isHidden = compact
        badges.isHidden = compact
        name.stringValue = isConversation ? row.title : URL(fileURLWithPath: row.title).lastPathComponent
        name.font = isConversation ? Theme.bodyEmphasis : Theme.body
        folder.stringValue = isConversation ? "" : ReviewSidebarFacts.folder(row.title)
        toolTip = row.title
        detail.stringValue = row.detail
        badges.stringValue = ReviewSidebarFacts.badges(row)
        badges.textColor = row.pendingCount > 0 ? Theme.running : Theme.secondaryText
        var parts = [row.title, row.detail, badges.stringValue].filter { !$0.isEmpty }
        if !isConversation && row.isViewed { parts.append(String(localized: "Viewed")) }
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
