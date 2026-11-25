import AppKit
import GitaCore

/// One provider row: state icon, title, branch, status and time (a pull request in `PullRequestColumns`, with its
/// number and author); inline Open ↗ / Copy; the title line toggles details, and an expanded pull request shows its
/// review in place under them (clicks in the expanded part never collapse the row).
@MainActor
final class ProviderDisclosureRow: RowView {
    private static let baseHeaderHeight: CGFloat = 30
    private static let dateToolTipFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMdjmm")
        return formatter
    }()

    let item: ProviderItem
    let openURL: URL?
    let zoomScale: CGFloat
    private let chevron = NSImageView()
    private var detail: ProviderDetailView?
    private weak var review: NSView?
    /// The in-place review of an expanded pull request (`PullRequestReviewController`); nil elsewhere.
    var makeReview: ((ProviderItem) -> NSView?)?
    private let body = Deck.vstack([], spacing: 0)
    var loader: ProviderDetailLoader?
    var onToggle: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    /// True when clicking a row opens a side-by-side review instead of expanding an inline accordion.
    var isSplitDetail = false {
        didSet {
            guard isSplitDetail != oldValue else { return }
            applyRowModeLayout()
        }
    }
    /// True while the side-by-side detail pane is open beside the list, narrowing rows to icon, number and title.
    var isNarrowSplit = false {
        didSet {
            guard isNarrowSplit != oldValue else { return }
            applyRowModeLayout()
        }
    }
    var isCompact = false {
        didSet {
            guard isCompact != oldValue else { return }
            applyRowModeLayout()
        }
    }
    private var headerBar: NSStackView?
    private var narrowHiddenViews: [NSView] = []
    private var compactHiddenViews: [NSView] = []
    var headerHeight: CGFloat { (Self.baseHeaderHeight * zoomScale).rounded() }

    init(item: ProviderItem, openURL: URL? = nil, zoomScale: CGFloat = 1) {
        self.item = item
        self.openURL = openURL ?? item.url
        self.zoomScale = zoomScale
        super.init(frame: .zero)
        bottomSeparator = Theme.separator.withAlphaComponent(0.6)
        onClick = { [weak self] in self?.onToggle?() }
        let statusText = Self.statusText(item)
        let header = Deck.hstack(headerViews(statusText: statusText), spacing: 10)
        header.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        header.heightAnchor.constraint(equalToConstant: headerHeight).isActive = true
        headerBar = header
        body.edgeInsets = NSEdgeInsets(top: 2, left: 58, bottom: 12, right: 18)
        let column = Deck.vstack([header, body], spacing: 0)
        Deck.pin(column, in: self)
        header.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        body.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        body.isHidden = true
        setAccessibilityLabel([item.title, item.branch, statusText].compactMap { $0 }.joined(separator: ", "))
        setExpanded(false)
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("ProviderDisclosureRow is built in code") }

    private func headerViews(statusText: String) -> [NSView] {
        if let pr = item.pullRequest, item.kind == .pullRequest { return pullRequestViews(pr) }
        let scale = zoomScale
        let icon = Deck.icon(Self.symbol(item), size: (12 * scale).rounded(), color: Self.color(item))
        icon.widthAnchor.constraint(equalToConstant: PullRequestColumns.iconWidth(scale)).isActive = true
        chevron.widthAnchor.constraint(equalToConstant: PullRequestColumns.chevronWidth(scale)).isActive = true
        let title = Deck.label(item.title, font: TextLines.system(12 * scale))
        let branch = Deck.label(item.branch ?? "", font: TextLines.monospaced(11 * scale), color: Theme.secondaryText)
        let status = Deck.label(statusText, font: TextLines.system(11 * scale), color: Self.color(item))
        let time = Deck.label(
            item.date.map { DeckFormat.relative($0) } ?? "", font: TextLines.system(11 * scale),
            color: Theme.secondaryText)
        time.toolTip = item.date.map(Self.dateToolTipFormatter.string(from:))
        for view in [branch, status, time] {
            view.setContentCompressionResistancePriority(.defaultHigh - 1, for: .horizontal)
        }
        branch.widthAnchor.constraint(lessThanOrEqualToConstant: (200 * scale).rounded()).isActive = true
        status.widthAnchor.constraint(equalToConstant: (150 * scale).rounded()).isActive = true
        time.widthAnchor.constraint(equalToConstant: (92 * scale).rounded()).isActive = true
        let actions = Deck.hstack(actionViews(), spacing: 6)
        actions.widthAnchor.constraint(greaterThanOrEqualToConstant: (96 * scale).rounded()).isActive = true
        return [chevron, icon, title, Deck.spacer(), branch, status, time, actions]
    }

    /// Number, title, branch, status pill, author, updated and actions at `PullRequestColumns`' scaled widths.
    private func pullRequestViews(_ pr: PullRequestSummary) -> [NSView] {
        let scale = zoomScale
        let icon = PullRequestColumns.fixed(
            Deck.icon(Self.symbol(item), size: (12 * scale).rounded(), color: Self.color(item)),
            PullRequestColumns.iconWidth(scale))
        chevron.widthAnchor.constraint(equalToConstant: PullRequestColumns.chevronWidth(scale)).isActive = true
        let number = Deck.label("#\(pr.number)", font: TextLines.monospaced(11 * scale), color: Theme.secondaryText)
        let titleWeight: NSFont.Weight = pr.lifecycle == .open && !pr.isDraft ? .medium : .regular
        let titleColor = pr.lifecycle == .closed ? Theme.secondaryText : Theme.text
        let title = Deck.label(
            PullRequestColumns.title(item.title, number: pr.number),
            font: TextLines.system(12 * scale, weight: titleWeight), color: titleColor)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.toolTip = item.title
        let branchBox = PullRequestColumns.branchView(item.branch, scale: scale)
        let statusBox = PullRequestColumns.statusBadge(pr, toolTip: Self.statusText(item), scale: scale)
        let authorBox = PullRequestColumns.author(pr.author, scale: scale)
        let time = Deck.label(
            item.date.map { DeckFormat.relative($0) } ?? "", font: TextLines.system(11 * scale),
            color: Theme.secondaryText)
        time.toolTip = item.date.map(Self.dateToolTipFormatter.string(from:))
        let updatedBox = PullRequestColumns.fixed(time, PullRequestColumns.updatedWidth(scale))
        let actions = Deck.hstack(actionViews(), spacing: 6)
        let actionsBox = PullRequestColumns.fixed(actions, PullRequestColumns.actionsWidth(scale))
        let spacer = Deck.spacer()
        narrowHiddenViews = [branchBox, statusBox, authorBox, updatedBox, actionsBox]
        compactHiddenViews = [title, spacer]
        return [
            chevron, icon, PullRequestColumns.fixed(number, PullRequestColumns.numberWidth(scale)), title, spacer,
            branchBox, statusBox, authorBox, updatedBox, actionsBox,
        ]
    }

    private func applyRowModeLayout() {
        chevron.isHidden = isSplitDetail || isCompact
        for view in narrowHiddenViews { view.isHidden = isNarrowSplit || isCompact }
        for view in compactHiddenViews { view.isHidden = isCompact }
        headerBar?.spacing = isCompact ? 4 : 10
        headerBar?.edgeInsets =
            isCompact
            ? NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
            : NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
    }

    /// Open ↗ on GitHub or the deployment, and Copy for a deployment's URL.
    private func actionViews() -> [NSView] {
        guard let url = Deck.safeWebURL(openURL) else { return [] }
        let open = PartsButton.openButton(
            item.kind == .deployment ? String(localized: "Open") : String(localized: "GitHub"), small: true
        ) { url }
        open.toolTip = url.absoluteString
        guard item.kind == .deployment else { return [open] }
        let copy = PartsButton.quiet("", symbol: "doc.on.doc") { Deck.copy(url.absoluteString) }
        copy.fixedHeight = 20
        copy.toolTip = String(localized: "Copy URL")
        copy.setAccessibilityLabel(String(localized: "Copy URL"))
        return [open, copy]
    }

    override var hoverRect: NSRect { NSRect(x: 0, y: 0, width: bounds.width, height: headerHeight) }
    override func acceptsClick(at point: NSPoint) -> Bool { point.y < headerHeight }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChange?(false)
    }

    func setExpanded(_ value: Bool) {
        let expandInline = value && !isSplitDetail
        chevron.setSymbol(
            expandInline ? "chevron.down" : "chevron.right", size: (9 * zoomScale).rounded(), weight: .semibold,
            color: Theme.tertiaryText)
        isSelected = value && isSplitDetail
        fill = expandInline ? Theme.inset : nil
        setAccessibilityExpanded(expandInline)
        guard expandInline else {
            body.isHidden = true
            detail?.removeFromSuperview()
            detail = nil
            review?.removeFromSuperview() // the controller keeps an unsent review for next time
            review = nil
            return
        }
        if detail == nil, let loader, item.target != nil {
            let view = ProviderDetailView(item: item, loader: loader)
            view.showsHeader = false
            detail = view
            body.addArrangedSubview(view)
            view.widthAnchor.constraint(
                equalTo: body.widthAnchor, constant: -(body.edgeInsets.left + body.edgeInsets.right)
            ).isActive = true
        }
        if review == nil, item.kind == .pullRequest, let view = makeReview?(item) {
            view.removeFromSuperview()
            body.addArrangedSubview(view)
            body.setCustomSpacing(10, after: detail ?? view)
            view.widthAnchor.constraint(
                equalTo: body.widthAnchor, constant: -(body.edgeInsets.left + body.edgeInsets.right)
            ).isActive = true
            review = view
        }
        body.isHidden = detail == nil && review == nil
    }

    static func statusText(_ item: ProviderItem) -> String {
        switch item.kind {
        case .pullRequest: item.pullRequest.map(HistoryChips.pullRequestLabel) ?? item.localizedDetail
        case .deployment: HistoryChips.deploymentDescription(item)
        default: item.localizedDetail
        }
    }
    static func symbol(_ item: ProviderItem) -> String {
        switch item.kind {
        case .pullRequest:
            item.pullRequest?.lifecycle == .merged ? "arrow.triangle.merge" : "arrow.triangle.pull"
        case .deployment: "triangle.fill"
        default: Style.stateSymbol(item.state)
        }
    }
    static func color(_ item: ProviderItem) -> NSColor {
        if let pr = item.pullRequest { return HistoryChips.pullRequestColor(pr) }
        return Theme.color(for: item.state)
    }
}
