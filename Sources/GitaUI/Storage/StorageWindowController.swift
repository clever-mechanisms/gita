import AppKit
import GitaCore

struct StorageWindowContext {
    var repositoryRoot: URL?
    var knownRepositories: [URL] = []
    var activeAgentPaths: Set<String> = []
    var onRemoveWorktree: ((URL, GitWorktree) -> Void)?
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
    private var outline = StorageOutlineView(frame: .zero)
    private var observer: UUID?
    private lazy var selector = ActionSegmentedControl(labels: [
        String(localized: "This Repository"), String(localized: "All Repositories"),
        String(localized: "Health & Maintenance"),
    ]) { [weak self] index in
        guard let self, let scope = Scope(rawValue: index) else { return }
        self.scope = scope
        loadScope()
    }

    init(store: StorageStore) {
        self.store = store
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 890, height: 610),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.delegate = self
        panel.title = String(localized: "Repository Storage & Health")
        panel.contentMinSize = NSSize(width: 760, height: 380)
        panel.isReleasedWhenClosed = false
        panel.center()
        panel.setFrameAutosaveName("RepositoryStorage")
        let frame = NSView()
        panel.contentView = frame
        let stack = Deck.vstack([selector, Deck.separator(), content], spacing: 14)
        Deck.pin(stack, in: frame, insets: NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18))
        content.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.arrangedSubviews[1].widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
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
        switch scope {
        case .repository:
            if let root = context.repositoryRoot { store.scanRepository(root, refresh: refresh) }
        case .workspace:
            store.scanWorkspace(context.knownRepositories, refresh: refresh)
        case .health:
            if let root = context.repositoryRoot { store.inspect(root) }
        }
        render()
    }

    @objc private func render() {
        window?.backgroundColor = Theme.window
        selector.selectedSegment = scope.rawValue
        selector.setEnabled(context.repositoryRoot != nil, forSegment: Scope.repository.rawValue)
        selector.setEnabled(context.repositoryRoot != nil, forSegment: Scope.health.rawValue)
        content.subviews.forEach { $0.removeFromSuperview() }
        let stack = Deck.vstack([], spacing: 12)
        Deck.pin(stack, in: content)
        switch scope {
        case .workspace: workspace(in: stack)
        case .repository, .health:
            if let root = context.repositoryRoot {
                if scope == .health { health(root, in: stack) } else { repository(root, in: stack) }
            }
        }
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        if !(stack.arrangedSubviews.last is NSScrollView) { stack.addArrangedSubview(NSView()) }
    }

    private func repository(_ root: URL, in stack: NSStackView) {
        let state = store.state(for: root)
        if let banner = StorageHealthView.banner(store.actionState(for: root)) { stack.addArrangedSubview(banner) }
        if case .scanning(_, let progress, _) = state {
            let label = progress.currentLabel
            let count = progress.scannedCheckouts
            let total = progress.totalCheckouts
            stack.addArrangedSubview(
                Deck.caption(
                    String(
                        localized:
                            "Scanning \(label) · \(count) of \(total) checkouts"
                    )))
        }
        guard let report = state.report ?? state.partialReport else {
            if let error = state.errorMessage {
                failure(error, in: stack)
            } else if !state.isScanning {
                stack.addArrangedSubview(
                    ActionButton(title: String(localized: "Refresh")) { [weak self] in
                        self?.loadScope()
                    })
            }
            return
        }
        let summary = StorageSummaryBar(
            report: report, refresh: { [weak self] in self?.loadScope(refresh: true) },
            trash: { [weak self] in self?.confirmTrash(report, entry: nil) })
        stack.addArrangedSubview(summary)
        outline.onSelectionChanged = { [weak summary] in summary?.updateSelection($0) }
        outline.onTrash = { [weak self] entry in self?.confirmTrash(report, entry: entry) }
        outline.onRemove = { [weak self] tree in self?.confirmRemoval(tree, report: report) }
        outline.display(
            StoragePresenter().outlineNodes(for: report, activeAgentPaths: context.activeAgentPaths, now: Date()))
        summary.updateSelection(outline.checked)
        stack.addArrangedSubview(outline)
    }

    private func workspace(in stack: NSStackView) {
        var rows = [RepositoryStorageReport]()
        var failures = [WorkspaceScanFailure]()
        switch store.workspaceState {
        case .idle: break
        case .failed(let message): failure(message, in: stack)
        case .scanning(let completed, let total, let partial, let partialFailures):
            stack.addArrangedSubview(Deck.caption(String(localized: "Scanned \(completed) of \(total) repositories")))
            rows = partial
            failures = partialFailures
        case .loaded(let reports, let scanFailures):
            rows = reports
            failures = scanFailures
            if rows.isEmpty && failures.isEmpty {
                stack.addArrangedSubview(Deck.caption(String(localized: "No repositories in this workspace.")))
            }
        }
        if !failures.isEmpty {
            let summary = failures.map { "\($0.root.lastPathComponent): \($0.message)" }.joined(separator: "\n")
            stack.addArrangedSubview(Deck.wrapping(summary, color: Theme.failure))
        }
        stack.addArrangedSubview(
            ActionButton(title: String(localized: "Refresh")) { [weak self] in self?.loadScope(refresh: true) })
        let list = StorageWorkspaceListView(rows: StoragePresenter().workspaceRows(for: rows)) { [weak self] root in
            guard let self else { return }
            context.repositoryRoot = root
            context.onOpenRepository?(root)
            scope = .repository
            outline = StorageOutlineView(frame: .zero)
            loadScope()
        }
        stack.addArrangedSubview(list)
    }

    private func health(_ root: URL, in stack: NSStackView) {
        switch store.healthState(for: root) {
        case .loaded(let snapshot):
            let state = store.actionState(for: root)
            let presenter = StoragePresenter()
            let active = presenter.hasActiveAgent(
                in: root, snapshot: snapshot, report: store.state(for: root).report,
                activeAgentPaths: context.activeAgentPaths)
            let cards = presenter.healthCards(for: snapshot, actionState: state, hasActiveAgent: active)
            stack.addArrangedSubview(
                StorageHealthView(cards: cards, actionState: state) { [weak self] action in
                    self?.perform(action, root: root)
                })
        case .idle, .loading: stack.addArrangedSubview(Deck.caption(String(localized: "Reading repository health…")))
        case .failed(let message): failure(message, in: stack)
        }
    }

    private func failure(_ message: String, in stack: NSStackView) {
        stack.addArrangedSubview(Deck.wrapping(message, color: Theme.failure))
        stack.addArrangedSubview(
            ActionButton(title: String(localized: "Retry")) { [weak self] in self?.loadScope(refresh: true) })
    }

    func reloadIfVisible() {
        if window?.isVisible == true { loadScope() }
    }

    var checked: Set<String> { outline.checked }
}
