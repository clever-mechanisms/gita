import AppKit
import GitaCore

/// Pull requests, workflow runs or deployments as a dense, zoomable list; the whole row expands its details in place
/// (or opens the side-by-side review in wide windows). Pull requests show under a header naming their columns and can
/// be grouped into sections (Open, Merged, Closed).
@MainActor
final class ProviderDisclosureList: NSView {
    struct Group: Equatable {
        enum Accent: Equatable { case open, merged, closed }

        var title: String?
        var accent: Accent?
        var items: [ProviderItem]
    }

    private let scroll = NSScrollView()
    private let stack = Deck.vstack([], spacing: 0)
    private let empty = Deck.label("", font: Theme.title, color: Theme.secondaryText)
    private lazy var clearFiltersButton = PartsButton.quiet(String(localized: "Show All")) { [weak self] in
        self?.onClearFilters?()
    }
    private let emptyStack: NSStackView
    private let columnsHost = NSView()
    private var columnsHeader: NSStackView?
    private let columnsLine = Deck.separator()
    private var columnsWidthConstraint: NSLayoutConstraint?
    private var groups: [Group] = []
    private var items: [ProviderItem] = []
    private var expanded: String?
    private var rows: [String: ProviderDisclosureRow] = [:]
    private var groupHeaders: [NSView] = []
    private var hasUpdated = false
    var loader: ProviderDetailLoader?
    /// An expanded pull request's in-place review.
    var makeReview: ((ProviderItem) -> NSView?)?
    var onSelectionChange: ((ProviderItem?) -> Void)?
    var onHoverItem: ((ProviderItem?) -> Void)?
    var onClearFilters: (() -> Void)?
    var selectedItem: ProviderItem? { items.first { Self.key($0) == expanded } }
    var emptyMessage = "" { didSet { empty.stringValue = emptyMessage } }
    var showsClearFilters = false {
        didSet { clearFiltersButton.isHidden = !showsClearFilters }
    }
    var zoomPercent = HistoryZoom.actual {
        didSet {
            let clamped = HistoryZoom.clamped(zoomPercent)
            if zoomPercent != clamped { zoomPercent = clamped }
            guard zoomPercent != oldValue else { return }
            applyZoomChange(from: oldValue, to: zoomPercent)
        }
    }
    var zoomScale: CGFloat { CGFloat(zoomPercent) / 100 }
    /// Whether selecting a row opens side-by-side detail rather than expanding inline.
    var usesSplitDetail = false {
        didSet {
            guard usesSplitDetail != oldValue else { return }
            rebuildColumnsHeader()
            syncPresentationMode()
        }
    }
    /// True while the side-by-side detail pane is visible beside the list (narrows columns to icon, number, title).
    var isShowingSplitDetail = false {
        didSet {
            guard isShowingSplitDetail != oldValue else { return }
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
        emptyStack = Deck.vstack([], spacing: 10)
        super.init(frame: frameRect)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        rebuildColumnsHeader()
        let column = Deck.vstack([columnsHost, columnsLine, scroll], spacing: 0)
        column.distribution = .fill
        Deck.pin(column, in: self)
        columnsWidthConstraint = columnsHost.widthAnchor.constraint(equalTo: column.widthAnchor)
        columnsLine.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        scroll.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        columnsHost.isHidden = true
        columnsLine.isHidden = true
        Deck.pin(stack, in: Deck.document(in: scroll))
        emptyStack.alignment = .centerX
        emptyStack.addArrangedSubview(empty)
        emptyStack.addArrangedSubview(clearFiltersButton)
        clearFiltersButton.isHidden = true
        clearFiltersButton.setAccessibilityIdentifier("provider.clearFilters")
        addSubview(emptyStack)
        emptyStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            emptyStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyStack.centerYAnchor.constraint(equalTo: centerYAnchor),
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
        let grouped = items.isEmpty ? [] : [Group(items: items)]
        update(groups: grouped, vercel: vercel)
    }

    func update(groups nextGroups: [Group], vercel: VercelContext? = nil) {
        guard !hasUpdated || self.groups != nextGroups || self.vercel != vercel else { return }
        hasUpdated = true
        self.vercel = vercel
        let previous = selectedItem
        self.groups = nextGroups
        self.items = nextGroups.flatMap(\.items)
        rebuildRows()
        if let expanded, rows[expanded] == nil { self.expanded = nil }
        emptyStack.isHidden = !items.isEmpty
        updateColumnsVisibility()
        if previous != selectedItem { onSelectionChange?(selectedItem) }
    }

    func clearSelection() {
        guard expanded != nil else { return }
        expanded = nil
        for row in rows.values { row.setExpanded(false) }
        onSelectionChange?(nil)
    }

    private func applyZoomChange(from oldPercent: Int, to newPercent: Int) {
        let clip = scroll.contentView
        let oldOrigin = clip.bounds.origin
        let ratio = CGFloat(newPercent) / CGFloat(max(1, oldPercent))
        rebuildColumnsHeader()
        if hasUpdated { rebuildRows() }
        clip.scroll(to: NSPoint(x: oldOrigin.x, y: oldOrigin.y < 0 ? oldOrigin.y : (oldOrigin.y * ratio).rounded()))
        scroll.reflectScrolledClipView(clip)
    }

    private func rebuildRows() {
        var next: [String: ProviderDisclosureRow] = [:]
        var headers: [NSView] = []
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let scale = zoomScale
        for group in groups {
            if let title = group.title {
                let header = Self.groupHeader(
                    title: title, count: group.items.count, accent: group.accent, scale: scale)
                header.isHidden = isCompact
                headers.append(header)
                stack.addArrangedSubview(header)
                header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
            for item in group.items {
                let id = Self.key(item)
                let row = reusableRow(id, item: item, openURL: vercel?.primaryURL(for: item) ?? item.url)
                row.onToggle = { [weak self] in self?.toggle(id) }
                row.onHoverChange = { [weak self] entered in
                    self?.onHoverItem?(entered ? item : nil)
                }
                row.loader = loader
                row.makeReview = makeReview
                row.isSplitDetail = usesSplitDetail
                row.isNarrowSplit = isShowingSplitDetail
                row.isCompact = isCompact
                row.setExpanded(id == expanded)
                next[id] = row
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }
        groupHeaders = headers
        rows = next
    }

    private static func groupHeader(title: String, count: Int, accent: Group.Accent?, scale: CGFloat) -> NSView {
        let (symbol, color): (String, NSColor) =
            switch accent {
            case .open: ("arrow.triangle.pull", Theme.success)
            case .merged: ("arrow.triangle.merge", Theme.merged)
            case .closed, nil: ("xmark.circle", Theme.secondaryText)
            }
        return ProviderGroupHeader(title: title, count: count, symbol: symbol, color: color, scale: scale)
    }

    private func rebuildColumnsHeader() {
        columnsHeader?.removeFromSuperview()
        let header = PullRequestColumns.header(scale: zoomScale, showsChevron: !usesSplitDetail)
        Deck.pin(header, in: columnsHost)
        columnsHeader = header
    }

    private func syncPresentationMode() {
        for header in groupHeaders { header.isHidden = isCompact }
        for (key, row) in rows {
            row.isSplitDetail = usesSplitDetail
            row.isNarrowSplit = isShowingSplitDetail
            row.isCompact = isCompact
            row.setExpanded(key == expanded)
        }
        updateColumnsVisibility()
    }

    private func updateColumnsVisibility() {
        let showsColumns = !isShowingSplitDetail && !isCompact && items.contains { $0.kind == .pullRequest }
        columnsWidthConstraint?.isActive = showsColumns
        columnsHost.isHidden = !showsColumns
        columnsLine.isHidden = !showsColumns
    }

    /// The row already shown for this item when nothing it shows changed, else a new one.
    private func reusableRow(_ id: String, item: ProviderItem, openURL: URL?) -> ProviderDisclosureRow {
        if let row = rows[id], row.item == item, row.openURL == openURL, abs(row.zoomScale - zoomScale) < 0.001 {
            return row
        }
        return ProviderDisclosureRow(item: item, openURL: openURL, zoomScale: zoomScale)
    }

    @discardableResult func select(_ item: ProviderItem) -> Bool {
        let id = Self.key(item)
        guard let row = rows[id] else { return false }
        if expanded != id { toggle(id) }
        DispatchQueue.main.async { row.scrollToVisible(row.bounds) }
        return true
    }

    private func toggle(_ id: String) {
        let previous = expanded
        expanded = expanded == id ? nil : id
        if let previous, previous != expanded { rows[previous]?.setExpanded(false) }
        if let expanded { rows[expanded]?.setExpanded(true) }
        onSelectionChange?(selectedItem)
    }
}
