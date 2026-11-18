import AppKit
import GitaCore

/// The pull request card (expanded in place by default) and the check rows of the Commit tab. Clicking a header
/// opens or closes its details.
@MainActor
enum ProviderCards {
    private enum Metrics {
        static let chevron: CGFloat = 9
        static let pullRequestIcon: CGFloat = 12
        static let stateIcon: CGFloat = 11
        static let titleIndent: CGFloat = 34
        static let headerInsets = NSEdgeInsets(top: 8, left: 14, bottom: 6, right: 14)
        static let runInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        static let runHeight: CGFloat = 28
    }

    static func pullRequest(_ item: ProviderItem, context: CommitDetailContext) -> NSView {
        let id = item.id
        let isOpen = !context.collapsedPullRequests.contains(id)
        let header = RowView()
        Deck.pin(pullRequestHeader(item, isOpen: isOpen), in: header, insets: Metrics.headerInsets)
        header.onClick = { context.togglePullRequest(id) }
        header.setAccessibilityLabel(item.title)
        header.setAccessibilityExpanded(isOpen)
        var rows: [NSView] = [header]
        if isOpen, let loader = context.loader, item.target != nil {
            rows.append(DetailRows.expandedDetail(item, loader: loader))
        }
        let view = DetailRows.card(rows)
        view.identifier = NSUserInterfaceItemIdentifier(id)
        return view
    }

    /// Chevron, glyph, state and Open on GitHub; the title wraps under them.
    private static func pullRequestHeader(_ item: ProviderItem, isOpen: Bool) -> NSView {
        let pr = item.pullRequest
        let merged = pr?.lifecycle == .merged
        let color = pr.map(HistoryChips.pullRequestColor) ?? Theme.success
        let state = Deck.label(
            pr.map(HistoryChips.pullRequestLabel) ?? item.localizedDetail, font: Theme.caption, color: color
        )
        state.setContentCompressionResistancePriority(.init(760), for: .horizontal)
        var views: [NSView] = [
            chevron(isOpen: isOpen, color: Theme.tertiaryText),
            Deck.icon(
                merged ? "arrow.triangle.merge" : "arrow.triangle.pull", size: Metrics.pullRequestIcon, color: color),
            state, Deck.spacer(),
        ]
        if let url = Deck.safeWebURL(item.url) {
            views.append(PartsButton.openButton(String(localized: "Open on GitHub"), small: true) { url })
        }
        let stack = Deck.hstack(views, spacing: 7)
        stack.distribution = .fill
        let title = Deck.wrapping(item.title, font: Theme.bodyEmphasis)
        title.toolTip = item.title
        let titleRow = NSView()
        Deck.pin(title, in: titleRow, insets: NSEdgeInsets(top: 0, left: Metrics.titleIndent, bottom: 0, right: 0))
        let column = Deck.vstack([stack, titleRow], spacing: 3)
        stack.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        titleRow.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        return column
    }

    /// A workflow run or Vercel CI run. Vercel CI runs have no detail read: no chevron (kept for alignment), no
    /// expansion.
    static func run(_ item: ProviderItem, context: CommitDetailContext) -> NSView {
        let id = item.id
        let isOpen = context.expanded.contains(id)
        let expandable = item.target != nil
        let header = RowView()
        Deck.pin(
            Deck.hstack(runViews(item, isOpen: isOpen, expandable: expandable), spacing: 7), in: header,
            insets: Metrics.runInsets)
        header.heightAnchor.constraint(equalToConstant: Metrics.runHeight).isActive = true
        header.setAccessibilityLabel("\(item.category), \(item.localizedDetail)")
        if expandable {
            header.onClick = { context.toggle(id) }
            header.setAccessibilityExpanded(isOpen)
        }
        var rows: [NSView] = [header]
        if isOpen, expandable, let loader = context.loader {
            rows.append(DetailRows.expandedDetail(item, loader: loader))
        }
        let view = DetailRows.card(rows)
        view.identifier = NSUserInterfaceItemIdentifier(id)
        return view
    }

    private static func runViews(_ item: ProviderItem, isOpen: Bool, expandable: Bool) -> [NSView] {
        let stateColor = Theme.color(for: item.state)
        var views: [NSView] = [
            chevron(isOpen: isOpen, color: expandable ? Theme.tertiaryText : .clear),
            Deck.icon(Style.stateSymbol(item.state), size: Metrics.stateIcon, color: stateColor),
            Deck.label(item.category, font: Theme.body), Deck.spacer(),
            Deck.label(item.localizedDetail, font: Theme.caption, color: stateColor),
            Deck.caption(runTime(item)),
        ]
        if let url = Deck.safeWebURL(item.url) {
            views.append(PartsButton.link(String(localized: "GitHub ↗")) { Deck.open(url) })
        }
        return views
    }

    /// How long the run took; Vercel CI reports when a run was created, not how long it took, so its age instead.
    static func runTime(_ item: ProviderItem) -> String {
        let elapsed = ProviderDetailView.elapsed(item.startedAt, item.date)
        guard elapsed.isEmpty && item.target == nil else { return elapsed }
        return item.date.map { DeckFormat.relative($0) } ?? ""
    }

    private static func chevron(isOpen: Bool, color: NSColor) -> NSView {
        Deck.icon(isOpen ? "chevron.down" : "chevron.right", size: Metrics.chevron, weight: .semibold, color: color)
    }
}
