import AppKit
import GitaCore

/// Current repository's sidebar pane: scoped search field (*"Filter branches, tags, stashes…"*), pages,
/// `★ Recent` branches from local reflog, branches, remotes, tags, stashes, and provider pages.
@MainActor
final class SidebarRepositoryPane: NSView, NSSearchFieldDelegate {
    private enum Metrics {
        static let filterInset: CGFloat = 10
        static let filterTop: CGFloat = 8
        static let listGap: CGFloat = 2
        static let listInset: CGFloat = 8
    }

    let list = SidebarPaneList()
    let filter = NSSearchField()
    var onRebuildRequested: (() -> Void)?

    private let state: SidebarState
    private var input = RepositorySidebarView.Input()
    private var lastQuery = ""
    private var loadedRecentBranches: [String] = []
    private var lastReflogRoot: URL?
    private var lastReflogKey: String?
    private var recentTask: Task<Void, Never>?

    var rows: [RepositorySidebarView.Row] { list.rows }
    private var query: String { filter.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }

    init(state: SidebarState) {
        self.state = state
        super.init(frame: .zero)
        configureList()
        configureFilter()
        layoutViews()
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    isolated deinit {
        recentTask?.cancel()
    }

    private func configureList() {
        list.configure(
            accessibilityLabel: String(localized: "References and pages"), allowsTypeSelect: false,
            contentInsets: NSEdgeInsets(top: Metrics.listInset, left: 0, bottom: Metrics.listInset, right: 0))
        list.actions.onSetGroupExpanded = { [weak self] id, expanded in
            guard let self else { return }
            self.state.setExpanded(id, expanded)
            self.onRebuildRequested?()
        }
    }

    private func configureFilter() {
        filter.placeholderString = String(localized: "Filter branches, tags, stashes…")
        filter.controlSize = .small
        filter.font = Theme.body
        filter.delegate = self
        filter.target = self
        filter.action = #selector(filterChanged)
        filter.sendsSearchStringImmediately = true
        filter.setAccessibilityLabel(String(localized: "Filter branches, tags, stashes"))
        filter.setAccessibilityIdentifier("sidebar.filter")
    }

    private func layoutViews() {
        for view in [filter, list.scroll] as [NSView] {
            addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            filter.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.filterInset),
            filter.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.filterInset),
            filter.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.filterTop),
            list.scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            list.scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            list.scroll.topAnchor.constraint(equalTo: filter.bottomAnchor, constant: Metrics.listGap),
            list.scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func update(_ next: RepositorySidebarView.Input) {
        var resolved = next
        if resolved.recentBranches.isEmpty, lastReflogRoot == resolved.currentRoot {
            resolved.recentBranches = loadedRecentBranches
        }
        input = resolved
        rebuild()
    }

    func loadRecentBranchesIfNeeded(for snapshot: RepositorySnapshot, service: GitService) {
        let branchCount = snapshot.references.count(where: { $0.kind == .branch })
        let key = "\(snapshot.root.path)\0\(snapshot.head ?? "")\0\(snapshot.branch ?? "")\0\(branchCount)"
        guard key != lastReflogKey else { return }
        lastReflogRoot = snapshot.root
        lastReflogKey = key
        recentTask?.cancel()
        recentTask = Task { @MainActor [weak self] in
            let branches = await service.recentBranches(limit: 5)
            guard let self, !Task.isCancelled, self.lastReflogKey == key else { return }
            guard branches != self.loadedRecentBranches else { return }
            self.loadedRecentBranches = branches
            self.input.recentBranches = branches
            self.rebuild()
        }
    }

    func rebuild() {
        let next = SidebarRowBuilder(
            input: input, query: query, repositoryExpansion: state.repositoryExpansion,
            groupExpansion: state.groupExpansion, order: state.repositoryOrder,
            key: { WindowAgents.key($0) }
        ).currentRepositoryRows()
        list.applyRows(next)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
            event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
            event.charactersIgnoringModifiers?.lowercased() == "f",
            let responder = window?.firstResponder as? NSView,
            responder === self || responder.isDescendant(of: self)
        else { return super.performKeyEquivalent(with: event) }
        window?.makeFirstResponder(filter)
        return true
    }

    func controlTextDidChange(_: Notification) { filterChanged() }

    @objc func filterChanged() {
        guard query != lastQuery else { return }
        lastQuery = query
        rebuild()
        list.scrollOffset = -.greatestFiniteMagnitude
    }
}
