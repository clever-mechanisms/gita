import AppKit
import GitaCore

/// One provider row: state icon, title, branch, status and time (a pull request in `PullRequestColumns`, with its
/// number and author); inline Open ↗ / Copy; the title line toggles details, and an expanded pull request shows its
/// review in place under them (clicks in the expanded part never collapse the row).
@MainActor
final class ProviderDisclosureRow: RowView {
    let item: ProviderItem
    let openURL: URL?
    private let chevron = NSImageView()
    private var detail: ProviderDetailView?
    private weak var review: NSView?
    /// The in-place review of an expanded pull request (`PullRequestReviewController`); nil elsewhere.
    var makeReview: ((ProviderItem) -> NSView?)?
    private let body = Deck.vstack([], spacing: 0)
    var loader: ProviderDetailLoader?
    var onToggle: (() -> Void)?
    private static let headerHeight: CGFloat = 30

    init(item: ProviderItem, openURL: URL? = nil) {
        self.item = item
        self.openURL = openURL ?? item.url
        super.init(frame: .zero)
        bottomSeparator = Theme.separator.withAlphaComponent(0.6)
        onClick = { [weak self] in self?.onToggle?() }
        let statusText = Self.statusText(item)
        let header = Deck.hstack(headerViews(statusText: statusText), spacing: 10)
        header.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        header.heightAnchor.constraint(equalToConstant: Self.headerHeight).isActive = true
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
        let icon = Deck.icon(Self.symbol(item), size: 12, color: Self.color(item))
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        chevron.widthAnchor.constraint(equalToConstant: 10).isActive = true
        let title = Deck.label(item.title, font: Theme.body)
        let branch = Deck.label(item.branch ?? "", font: Theme.mono, color: Theme.secondaryText)
        let status = Deck.label(statusText, font: Theme.caption, color: Self.color(item))
        let time = Deck.label(
            item.date.map { DeckFormat.relative($0) } ?? "", font: Theme.caption, color: Theme.secondaryText)
        for view in [branch, status, time] {
            view.setContentCompressionResistancePriority(.defaultHigh - 1, for: .horizontal)
        }
        branch.widthAnchor.constraint(lessThanOrEqualToConstant: 200).isActive = true
        status.widthAnchor.constraint(equalToConstant: 150).isActive = true
        time.widthAnchor.constraint(equalToConstant: 92).isActive = true
        let actions = Deck.hstack(actionViews(), spacing: 6)
        actions.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
        return [chevron, icon, title, Deck.spacer(), branch, status, time, actions]
    }
    /// Number, title, branch, status, author and updated, at `PullRequestColumns`' widths.
    private func pullRequestViews(_ pr: PullRequestSummary) -> [NSView] {
        let icon = PullRequestColumns.fixed(Deck.icon(Self.symbol(item), size: 12, color: Self.color(item)), 16)
        chevron.widthAnchor.constraint(equalToConstant: 10).isActive = true
        let number = Deck.label("#\(pr.number)", font: Theme.mono, color: Theme.secondaryText)
        let title = Deck.label(PullRequestColumns.title(item.title, number: pr.number), font: Theme.body)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.toolTip = item.title
        let branch = Deck.label(item.branch ?? "", font: Theme.mono, color: Theme.secondaryText)
        branch.lineBreakMode = .byTruncatingMiddle
        branch.toolTip = item.branch
        let status = Deck.label(PullRequestColumns.status(pr), font: Theme.caption, color: Self.color(item))
        status.lineBreakMode = .byTruncatingTail
        status.toolTip = Self.statusText(item)
        let time = Deck.label(
            item.date.map { DeckFormat.relative($0) } ?? "", font: Theme.caption, color: Theme.secondaryText)
        let actions = Deck.hstack(actionViews(), spacing: 6)
        return [
            chevron, icon, PullRequestColumns.fixed(number, PullRequestColumns.number), title, Deck.spacer(),
            PullRequestColumns.fixed(branch, PullRequestColumns.branch),
            PullRequestColumns.fixed(status, PullRequestColumns.status), PullRequestColumns.author(pr.author),
            PullRequestColumns.fixed(time, PullRequestColumns.updated),
            PullRequestColumns.fixed(actions, PullRequestColumns.actions),
        ]
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

    override var hoverRect: NSRect { NSRect(x: 0, y: 0, width: bounds.width, height: Self.headerHeight) }
    override func acceptsClick(at point: NSPoint) -> Bool { point.y < Self.headerHeight }

    func setExpanded(_ value: Bool) {
        chevron.setSymbol(
            value ? "chevron.down" : "chevron.right", size: 9, weight: .semibold, color: Theme.tertiaryText)
        isSelected = false
        fill = value ? Theme.inset : nil
        setAccessibilityExpanded(value)
        guard value else {
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
