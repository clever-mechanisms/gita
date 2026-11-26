import AppKit
import GitaCore

struct StorageWindowContext {
    var repositoryRoot: URL?
    var knownRepositories: [URL] = []
    var activeAgentPaths: Set<String> = []
    var onRemoveWorktree: ((URL, GitWorktree) -> Bool)?
    var onOpenRepository: ((URL) -> Void)?
}

@MainActor
final class StorageWindowController: NSWindowController, NSWindowDelegate {
    enum Scope: Int {
        case repository, workspace, health
    }

    let store: StorageStore
    private(set) var context = StorageWindowContext()
    private var scope = Scope.repository
    private let content = NSView()
    private let headerBar = FillView(color: Theme.toolbar)
    private var outline = StorageOutlineView(frame: .zero)
    private var observer: UUID?
    private lazy var selector: ActionSegmentedControl = {
        let control = ActionSegmentedControl(labels: [
            String(localized: "This Repository"), String(localized: "All Repositories"),
            String(localized: "Health & Maintenance"),
        ]) { [weak self] index in
            guard let self, let scope = Scope(rawValue: index) else { return }
            self.scope = scope
            loadScope()
        }
        let symbols = ["internaldrive", "square.stack.3d.up", "stethoscope"]
        for (index, name) in symbols.enumerated() {
            control.setImage(Deck.template(name, size: 12, weight: .medium), forSegment: index)
            control.setImageScaling(.scaleProportionallyDown, forSegment: index)
        }
        control.segmentStyle = .automatic
        control.segmentDistribution = .fit
        return control
    }()

    init(store: StorageStore) {
        self.store = store
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.delegate = self
        panel.title = String(localized: "Repository Storage & Health")
        panel.contentMinSize = NSSize(width: 780, height: 420)
        panel.isReleasedWhenClosed = false
        panel.center()
        panel.setFrameAutosaveName("RepositoryStorage")

        let rootView = ThemedBackgroundView()
        panel.contentView = rootView
        let headerDivider = Deck.separator()
        headerBar.addSubview(selector)
        selector.translatesAutoresizingMaskIntoConstraints = false
        for subview in [headerBar, headerDivider, content] as [NSView] {
            rootView.addSubview(subview)
            subview.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            headerBar.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            headerBar.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            headerBar.topAnchor.constraint(equalTo: rootView.topAnchor),
            headerBar.heightAnchor.constraint(equalToConstant: 48),
            selector.centerXAnchor.constraint(equalTo: headerBar.centerXAnchor),
            selector.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            headerDivider.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            headerDivider.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            headerDivider.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            content.topAnchor.constraint(equalTo: headerDivider.bottomAnchor),
            content.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(render), name: .gitaThemeChanged, object: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("StorageWindowController is built in code") }

    func show(context: StorageWindowContext, scope: Scope = .repository) {
        self.context = context
        self.context.activeAgentPaths = Set(
            context.activeAgentPaths.map {
                URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path
            })
        self.scope = context.repositoryRoot == nil ? .workspace : scope
        outline = StorageOutlineView(frame: .zero)
        if observer == nil { observer = store.addObserver { [weak self] in self?.render() } }
        guard let window else { return }
        AuxiliaryWindowActivation.show(window)
        loadScope()
    }

    func windowWillClose(_: Notification) {
        if let observer { store.removeObserver(observer) }
        observer = nil
        store.cancelActiveScans()
        AuxiliaryWindowActivation.closing(window)
    }

    func loadScope(refresh: Bool = false) {
        if scope == .workspace {
            store.scanWorkspace(context.knownRepositories, refresh: refresh)
        } else if let root = context.repositoryRoot {
            loadRepositoryScope(root, refresh: refresh)
        }
        render()
    }

    private func loadRepositoryScope(_ root: URL, refresh: Bool) {
        if scope == .health { store.inspect(root) } else { store.scanRepository(root, refresh: refresh) }
    }

    @objc private func render() {
        let savedScrollOrigin = (content.subviews.first as? NSScrollView)?.contentView.bounds.origin
        window?.backgroundColor = Theme.window
        headerBar.color = Theme.toolbar
        selector.selectedSegment = scope.rawValue
        let hasRoot = context.repositoryRoot != nil
        selector.setEnabled(hasRoot, forSegment: Scope.repository.rawValue)
        selector.setEnabled(hasRoot, forSegment: Scope.health.rawValue)
        content.subviews.forEach { $0.removeFromSuperview() }
        renderCurrentScope()
        if let savedScrollOrigin, let scroll = content.subviews.first as? NSScrollView {
            scroll.layoutSubtreeIfNeeded()
            scroll.contentView.scroll(to: savedScrollOrigin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    private func renderCurrentScope() {
        if scope == .workspace {
            renderWorkspaceScope()
            return
        }
        guard let root = context.repositoryRoot else { return }
        if scope == .health { renderHealthScope(root) } else { renderRepositoryScope(root) }
    }

    private func renderRepositoryScope(_ root: URL) {
        let state = store.state(for: root)
        guard let report = state.report ?? state.partialReport else {
            renderEmptyRepository(state, actionState: store.actionState(for: root))
            return
        }
        renderRepositoryReport(report, scanState: state, actionState: store.actionState(for: root))
    }

    private func renderEmptyRepository(_ state: StorageScanState, actionState: HealthActionState) {
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
                    self?.loadScope()
                })
        }
        StorageStyle.pinTopInset(stack, in: content, top: 16)
    }

    private func renderRepositoryReport(
        _ report: RepositoryStorageReport, scanState: StorageScanState, actionState: HealthActionState
    ) {
        let summary = StorageSummaryBar(
            report: report, refresh: { [weak self] in self?.loadScope(refresh: true) },
            trash: { [weak self] in self?.confirmTrash(report, entry: nil) })
        let topStack = makeReportTopStack(summary: summary, scanState: scanState, actionState: actionState)
        let outlineCard = wrapOutlineInCard()
        let footer = StorageSelectionFooter(report: report) { [weak self] in
            self?.confirmTrash(report, entry: nil)
        }
        bindOutline(for: report, summary: summary, footer: footer)
        layoutRepositoryReport(topStack: topStack, outlineCard: outlineCard, footer: footer)
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
        for report: RepositoryStorageReport, summary: StorageSummaryBar, footer: StorageSelectionFooter
    ) {
        outline.onSelectionChanged = { [weak summary, weak footer] checked in
            summary?.updateSelection(checked)
            footer?.updateSelection(checked)
        }
        outline.onTrash = { [weak self] entry in self?.confirmTrash(report, entry: entry) }
        outline.onRemove = { [weak self] tree in self?.confirmRemoval(tree, report: report) }
        outline.display(
            StoragePresenter().outlineNodes(for: report, activeAgentPaths: context.activeAgentPaths, now: Date()))
        summary.updateSelection(outline.checked)
        footer.updateSelection(outline.checked)
    }

    private func layoutRepositoryReport(topStack: NSView, outlineCard: NSView, footer: NSView) {
        let footerDivider = Deck.separator()
        for subview in [topStack, outlineCard, footerDivider, footer] as [NSView] {
            content.addSubview(subview)
            subview.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            topStack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            topStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            topStack.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            outlineCard.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            outlineCard.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            outlineCard.topAnchor.constraint(equalTo: topStack.bottomAnchor, constant: 12),
            outlineCard.bottomAnchor.constraint(equalTo: footerDivider.topAnchor, constant: -12),
            footerDivider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footerDivider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footerDivider.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    private func scanningCaption(for state: StorageScanState) -> NSView? {
        guard case .scanning(_, let progress, _) = state else { return nil }
        let label = progress.currentLabel
        let count = progress.scannedCheckouts
        let total = progress.totalCheckouts
        return Deck.caption(String(localized: "Scanning \(label) · \(count) of \(total) checkouts"))
    }

    private func renderWorkspaceScope() {
        let presenter = StoragePresenter()
        let listState: StorageWorkspaceListState =
            switch store.workspaceState {
            case .idle: .idle
            case .scanning(let completed, let total, let partial, let failures):
                .scanning(
                    completed: completed, total: total,
                    rows: presenter.workspaceRows(for: partial), failureMessage: formatFailures(failures))
            case .loaded(let reports, let failures):
                .loaded(rows: presenter.workspaceRows(for: reports), failureMessage: formatFailures(failures))
            case .failed(let message): .failed(message)
            }
        let list = StorageWorkspaceListView(
            state: listState,
            refresh: { [weak self] in self?.loadScope(refresh: true) },
            inspect: { [weak self] root in self?.openWorkspaceRepository(root) })
        Deck.pin(list, in: content)
    }

    private func formatFailures(_ failures: [WorkspaceScanFailure]) -> String? {
        guard !failures.isEmpty else { return nil }
        return failures.map { "\($0.root.lastPathComponent): \($0.message)" }.joined(separator: "\n")
    }

    private func openWorkspaceRepository(_ root: URL) {
        context.repositoryRoot = root
        context.onOpenRepository?(root)
        scope = .repository
        outline = StorageOutlineView(frame: .zero)
        loadScope()
    }

    private func renderHealthScope(_ root: URL) {
        switch store.healthState(for: root) {
        case .loaded(let snapshot):
            let state = store.actionState(for: root)
            let presenter = StoragePresenter()
            let active = presenter.hasActiveAgent(
                in: root, snapshot: snapshot, report: store.state(for: root).report,
                activeAgentPaths: context.activeAgentPaths)
            let summary = presenter.healthSummary(for: snapshot, actionState: state)
            let cards = presenter.healthCards(for: snapshot, actionState: state, hasActiveAgent: active)
            let healthView = StorageHealthView(summary: summary, cards: cards, actionState: state) {
                [weak self] action in
                self?.perform(action, root: root)
            }
            Deck.pin(healthView, in: content)
        case .idle, .loading:
            StorageStyle.pinTopInset(Deck.caption(String(localized: "Reading repository health…")), in: content)
        case .failed(let message):
            let stack = Deck.vstack([], spacing: 12)
            appendFailure(message, to: stack)
            StorageStyle.pinTopInset(stack, in: content)
        }
    }

    private func appendFailure(_ message: String, to stack: NSStackView) {
        if let banner = StorageStyle.banner(.failed(message)) { StorageStyle.addFullWidth(banner, to: stack) }
        stack.addArrangedSubview(
            StorageStyle.actionButton(String(localized: "Retry"), symbol: "arrow.clockwise") { [weak self] in
                self?.loadScope(refresh: true)
            })
    }

    func reloadIfVisible() {
        if window?.isVisible == true { loadScope() }
    }

    var checked: Set<String> { outline.checked }
}
