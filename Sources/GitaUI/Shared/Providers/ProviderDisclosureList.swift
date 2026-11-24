import AppKit
import GitaCore

/// Pull requests, workflow runs or deployments as a dense list; the whole row expands its details in place (a pull
/// request's review too). Pull requests show under a header naming their columns.
/// Rows carry their obvious action inline (Open ↗ on GitHub or the deployment, Copy for deployment URLs).
@MainActor
final class ProviderDisclosureList: NSView {
    private let scroll = NSScrollView()
    private let stack = Deck.vstack([], spacing: 0)
    private let empty = Deck.label("", font: Theme.title, color: Theme.secondaryText)
    private let columns = PullRequestColumns.header()
    private let columnsLine = Deck.separator()
    private var columnsWidthConstraint: NSLayoutConstraint?
    private var items: [ProviderItem] = []
    private var expanded: String?
    private var rows: [String: ProviderDisclosureRow] = [:]
    private var hasUpdated = false
    var loader: ProviderDetailLoader?
    /// An expanded pull request's in-place review.
    var makeReview: ((ProviderItem) -> NSView?)?
    var onSelectionChange: ((ProviderItem?) -> Void)?
    var selectedItem: ProviderItem? { items.first { Self.key($0) == expanded } }
    var emptyMessage = "" { didSet { empty.stringValue = emptyMessage } }
    var usesSplitDetail = false {
        didSet {
            guard usesSplitDetail != oldValue else { return }
            syncPresentationMode()
        }
    }
    var isCompact = false {
        didSet {
            guard isCompact != oldValue else { return }
            syncPresentationMode()
        }
    }
    /// Gives each deployment row its main URL (`VercelContext.primaryURL`).
    private var vercel: VercelContext?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let column = Deck.vstack([columns, columnsLine, scroll], spacing: 0)
        column.distribution = .fill
        Deck.pin(column, in: self)
        columnsWidthConstraint = columns.widthAnchor.constraint(equalTo: column.widthAnchor)
        columnsLine.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        scroll.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        columns.isHidden = true
        columnsLine.isHidden = true
        Deck.pin(stack, in: Deck.document(in: scroll))
        addSubview(empty)
        empty.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            empty.centerXAnchor.constraint(equalTo: centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityRole(.list)
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("ProviderDisclosureList is built in code") }

    /// A row's identity across updates: its provider target, else provider and id.
    static func key(_ item: ProviderItem) -> String {
        if let target = item.target { return "\(target)" }
        return "\(item.provider.rawValue):\(item.id)"
    }

    func update(items: [ProviderItem], vercel: VercelContext? = nil) {
        guard !hasUpdated || self.items != items || self.vercel != vercel else { return }
        hasUpdated = true
        self.vercel = vercel
        let previous = selectedItem
        self.items = items
        var next: [String: ProviderDisclosureRow] = [:]
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for item in items {
            let id = Self.key(item)
            let row = reusableRow(id, item: item, openURL: vercel?.primaryURL(for: item) ?? item.url)
            row.onToggle = { [weak self] in self?.toggle(id) }
            row.loader = loader
            row.makeReview = makeReview
            row.isSplitDetail = usesSplitDetail
            row.isCompact = isCompact
            row.setExpanded(id == expanded)
            next[id] = row
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        rows = next
        if let expanded, next[expanded] == nil { self.expanded = nil }
        empty.isHidden = !items.isEmpty
        updateColumnsVisibility()
        if previous != selectedItem { onSelectionChange?(selectedItem) }
    }

    func clearSelection() {
        guard expanded != nil else { return }
        expanded = nil
        for row in rows.values { row.setExpanded(false) }
        onSelectionChange?(nil)
    }

    private func syncPresentationMode() {
        for (key, row) in rows {
            row.isSplitDetail = usesSplitDetail
            row.isCompact = isCompact
            row.setExpanded(key == expanded)
        }
        updateColumnsVisibility()
    }

    private func updateColumnsVisibility() {
        let showsColumns = !usesSplitDetail && !isCompact && items.contains { $0.kind == .pullRequest }
        columnsWidthConstraint?.isActive = showsColumns
        columns.isHidden = !showsColumns
        columnsLine.isHidden = !showsColumns
    }
    /// The row already shown for this item when nothing it shows changed, else a new one.
    private func reusableRow(_ id: String, item: ProviderItem, openURL: URL?) -> ProviderDisclosureRow {
        if let row = rows[id], row.item == item, row.openURL == openURL { return row }
        return ProviderDisclosureRow(item: item, openURL: openURL)
    }
    @discardableResult func select(_ item: ProviderItem) -> Bool {
        let id = Self.key(item)
        guard let row = rows[id] else { return false }
        if expanded != id { toggle(id) }
        DispatchQueue.main.async { row.scrollToVisible(row.bounds) }
        return true
    }
    private func toggle(_ id: String) {
        expanded = expanded == id ? nil : id
        for (key, row) in rows { row.setExpanded(key == expanded) }
        onSelectionChange?(selectedItem)
    }
}
