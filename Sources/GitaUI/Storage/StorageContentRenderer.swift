import AppKit
import GitaCore

/// Host surface providing window, context, and reload hooks for `StorageContentRenderer`.
@MainActor
protocol StorageContentHost: AnyObject {
    var store: StorageStore { get }
    var context: StorageWindowContext { get }
    var hostWindow: NSWindow? { get }
    func loadScope(refresh: Bool)
    func reloadIfVisible()
}

/// Shared Disk Usage and Health & Maintenance content rendering for both inline and window storage hosts.
@MainActor
final class StorageContentRenderer {
    private let store: StorageStore
    private weak var host: (any StorageContentHost)?
    private(set) var outline = StorageOutlineView(frame: .zero)
    var checked: Set<String> { outline.checked }

    private lazy var actions = StorageActionCoordinator(
        store: store,
        windowProvider: { [weak self] in self?.host?.hostWindow },
        contextProvider: { [weak self] in self?.host?.context ?? StorageWindowContext() },
        checkedProvider: { [weak self] in self?.checked ?? [] },
        onDidMutate: { [weak self] in self?.host?.reloadIfVisible() })

    init(host: any StorageContentHost) {
        self.store = host.store
        self.host = host
    }

    func resetOutline() {
        outline = StorageOutlineView(frame: .zero)
    }

    static func normalizedContext(_ context: StorageWindowContext) -> StorageWindowContext {
        var normalized = context
        normalized.activeAgentPaths = Set(
            context.activeAgentPaths.map {
                URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path
            })
        return normalized
    }

    func renderPreservingScroll(in container: NSView, body: () -> Void) {
        let savedScrollOrigin = (container.subviews.first as? NSScrollView)?.contentView.bounds.origin
        container.subviews.forEach { $0.removeFromSuperview() }
        body()
        if let savedScrollOrigin, let scroll = container.subviews.first as? NSScrollView {
            scroll.layoutSubtreeIfNeeded()
            scroll.contentView.scroll(to: savedScrollOrigin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    func renderScope(
        root: URL, showHealth: Bool, in container: NSView, context: StorageWindowContext,
        openGlobalSettings: (() -> Void)? = nil
    ) {
        if showHealth {
            renderHealth(root: root, in: container, context: context, openGlobalSettings: openGlobalSettings)
        } else {
            renderRepository(root: root, in: container, context: context)
        }
    }

    private func renderRepository(root: URL, in container: NSView, context: StorageWindowContext) {
        let state = store.state(for: root)
        guard let report = state.report ?? state.partialReport else {
            renderEmptyRepository(state, actionState: store.actionState(for: root), in: container)
            return
        }
        renderRepositoryReport(report, scanState: state, in: container, context: context)
    }

    private func renderHealth(
        root: URL, in container: NSView, context: StorageWindowContext, openGlobalSettings: (() -> Void)?
    ) {
        switch store.healthState(for: root) {
        case .loaded(let snapshot):
            let state = store.actionState(for: root)
            let presenter = StoragePresenter()
            let active = presenter.hasActiveAgent(
                in: root, snapshot: snapshot, report: store.state(for: root).report,
                activeAgentPaths: context.activeAgentPaths)
            let summary = presenter.healthSummary(for: snapshot, actionState: state)
            let cards = presenter.healthCards(for: snapshot, actionState: state, hasActiveAgent: active)
            let healthView = StorageHealthView(
                summary: summary, cards: cards, actionState: state,
                openGlobalSettings: openGlobalSettings,
                perform: { [weak self] action in self?.actions.perform(action, root: root) })
            Deck.pin(healthView, in: container)
        case .idle, .loading:
            StorageStyle.pinTopInset(Deck.caption(String(localized: "Reading repository health…")), in: container)
        case .failed(let message):
            let stack = Deck.vstack([], spacing: 12)
            appendFailure(message, to: stack)
            StorageStyle.pinTopInset(stack, in: container)
        }
    }

    private func renderEmptyRepository(
        _ state: StorageScanState, actionState: HealthActionState, in container: NSView
    ) {
        let stack = Deck.vstack([], spacing: 12)
        if let banner = StorageStyle.banner(actionState) { StorageStyle.addFullWidth(banner, to: stack) }
        if let caption = scanningCaption(for: state) {
            stack.addArrangedSubview(caption)
        } else if let error = state.errorMessage {
            appendFailure(error, to: stack)
        } else {
            stack.addArrangedSubview(Deck.caption(String(localized: "Not scanned yet.")))
            stack.addArrangedSubview(
                StorageStyle.actionButton(String(localized: "Scan"), symbol: "arrow.clockwise") { [weak self] in
                    self?.host?.loadScope(refresh: false)
                })
        }
        StorageStyle.pinTopInset(stack, in: container, top: 16)
    }

    private func renderRepositoryReport(
        _ report: RepositoryStorageReport, scanState: StorageScanState, in container: NSView,
        context: StorageWindowContext
    ) {
        let actionState = store.actionState(for: report.mainRoot)
        let summary = StorageSummaryBar(
            report: report, refresh: { [weak self] in self?.host?.loadScope(refresh: true) },
            trash: { [weak self] in self?.actions.confirmTrash(report, entry: nil) })
        let topStack = makeReportTopStack(summary: summary, scanState: scanState, actionState: actionState)
        let outlineCard = wrapOutlineInCard()
        let footer = StorageSelectionFooter(report: report) { [weak self] in
            self?.actions.confirmTrash(report, entry: nil)
        }
        bindOutline(for: report, summary: summary, footer: footer, context: context)
        layoutRepositoryReport(in: container, topStack: topStack, outlineCard: outlineCard, footer: footer)
    }

    private func makeReportTopStack(
        summary: StorageSummaryBar, scanState: StorageScanState, actionState: HealthActionState
    ) -> NSStackView {
        let topStack = Deck.vstack([], spacing: 10)
        if let banner = StorageStyle.banner(actionState) { StorageStyle.addFullWidth(banner, to: topStack) }
        if let caption = scanningCaption(for: scanState) { topStack.addArrangedSubview(caption) }
        StorageStyle.addFullWidth(summary, to: topStack)
        return topStack
    }

    private func wrapOutlineInCard() -> NSView {
        let card = StorageStyle.card(cornerRadius: 10)
        let clipHolder = NSView()
        clipHolder.wantsLayer = true
        clipHolder.layer?.cornerRadius = 9
        clipHolder.layer?.masksToBounds = true
        Deck.pin(outline, in: clipHolder)
        Deck.pin(clipHolder, in: card, insets: NSEdgeInsets(top: 1, left: 1, bottom: 1, right: 1))
        return card
    }

    private func bindOutline(
        for report: RepositoryStorageReport, summary: StorageSummaryBar, footer: StorageSelectionFooter,
        context: StorageWindowContext
    ) {
        outline.onSelectionChanged = { [weak summary, weak footer] checked in
            summary?.updateSelection(checked)
            footer?.updateSelection(checked)
        }
        outline.onTrash = { [weak self] entry in self?.actions.confirmTrash(report, entry: entry) }
        outline.onRemove = { [weak self] tree in self?.actions.confirmRemoval(tree, report: report) }
        outline.display(
            StoragePresenter().outlineNodes(for: report, activeAgentPaths: context.activeAgentPaths, now: Date()))
        summary.updateSelection(outline.checked)
        footer.updateSelection(outline.checked)
    }

    private func layoutRepositoryReport(
        in container: NSView, topStack: NSView, outlineCard: NSView, footer: NSView
    ) {
        let footerDivider = Deck.separator()
        for subview in [topStack, outlineCard, footerDivider, footer] as [NSView] {
            container.addSubview(subview)
            subview.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            topStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            topStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            topStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            outlineCard.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            outlineCard.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            outlineCard.topAnchor.constraint(equalTo: topStack.bottomAnchor, constant: 12),
            outlineCard.bottomAnchor.constraint(equalTo: footerDivider.topAnchor, constant: -12),
            footerDivider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footerDivider.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footerDivider.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    private func scanningCaption(for state: StorageScanState) -> NSView? {
        guard case .scanning(_, let progress, _) = state else { return nil }
        let label = progress.currentLabel
        let count = progress.scannedCheckouts
        let total = progress.totalCheckouts
        return Deck.caption(String(localized: "Scanning \(label) · \(count) of \(total) checkouts"))
    }

    private func appendFailure(_ message: String, to stack: NSStackView) {
        if let banner = StorageStyle.banner(.failed(message)) { StorageStyle.addFullWidth(banner, to: stack) }
        stack.addArrangedSubview(
            StorageStyle.actionButton(String(localized: "Retry"), symbol: "arrow.clockwise") { [weak self] in
                self?.host?.loadScope(refresh: true)
            })
    }
}
