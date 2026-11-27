import AppKit
import GitaCore

struct StorageWindowContext {
    var repositoryRoot: URL?
    var knownRepositories: [URL] = []
    var activeAgentPaths: Set<String> = []
    var onRemoveWorktree: ((URL, GitWorktree) -> Bool)?
    var onOpenRepository: ((URL) -> Void)?
}

/// Global multi-repository Workspace Storage window listing disk usage across all known repositories.
@MainActor
final class StorageWindowController: NSWindowController, NSWindowDelegate {
    let store: StorageStore
    private(set) var context = StorageWindowContext()
    private let content = NSView()
    private let headerBar = FillView(color: Theme.toolbar)
    private var observer: UUID?
    var onOpenGlobalSettings: (() -> Void)?

    private lazy var globalSettingsButton: PartsButton = {
        let button = StorageStyle.actionButton(
            String(localized: "Global Defaults…"), symbol: "gearshape", style: .quiet,
            accessibility: String(localized: "Global Defaults…")
        ) { [weak self] in
            self?.onOpenGlobalSettings?()
        }
        button.setAccessibilityIdentifier("storage.workspace.globalDefaults")
        return button
    }()

    init(store: StorageStore) {
        self.store = store
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.delegate = self
        panel.title = String(localized: "Workspace Storage")
        panel.contentMinSize = NSSize(width: 780, height: 420)
        panel.isReleasedWhenClosed = false
        panel.center()
        panel.setFrameAutosaveName("RepositoryStorage")

        let rootView = ThemedBackgroundView()
        panel.contentView = rootView
        buildHeaderBar()
        StorageStyle.layoutHeaderChrome(headerBar: headerBar, content: content, in: rootView)
        NotificationCenter.default.addObserver(self, selector: #selector(render), name: .gitaThemeChanged, object: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("StorageWindowController is built in code") }

    func show(context: StorageWindowContext) {
        self.context = StorageContentRenderer.normalizedContext(context)
        if observer == nil { observer = store.addObserver { [weak self] in self?.render() } }
        guard let window else { return }
        AuxiliaryWindowActivation.show(window)
        loadWorkspace()
    }

    func windowWillClose(_: Notification) {
        if let observer { store.removeObserver(observer) }
        observer = nil
        store.cancelActiveScans()
        AuxiliaryWindowActivation.closing(window)
    }

    func loadWorkspace(refresh: Bool = false) {
        store.scanWorkspace(context.knownRepositories, refresh: refresh)
        render()
    }

    func reloadIfVisible() {
        if window?.isVisible == true { loadWorkspace() }
    }

    private func buildHeaderBar() {
        let badge = StorageStyle.iconBadge(
            "square.stack.3d.up", tint: Theme.accent, boxSize: 28, symbolSize: 13, cornerRadius: 7)
        let titleLabel = Deck.label(String(localized: "Workspace Storage"), font: Theme.bodyEmphasis)
        let subtitleLabel = Deck.caption(String(localized: "All Repositories"))
        let titleColumn = Deck.vstack([titleLabel, subtitleLabel], spacing: 1)
        let leading = Deck.hstack([badge, titleColumn], spacing: 10)
        globalSettingsButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = Deck.hstack([leading, Deck.spacer(), globalSettingsButton], spacing: 12)
        Deck.pin(row, in: headerBar, insets: NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16))
    }

    @objc private func render() {
        window?.backgroundColor = Theme.window
        headerBar.color = Theme.toolbar
        let savedScrollOrigin = (content.subviews.first as? NSScrollView)?.contentView.bounds.origin
        content.subviews.forEach { $0.removeFromSuperview() }
        renderWorkspaceScope()
        if let savedScrollOrigin, let scroll = content.subviews.first as? NSScrollView {
            scroll.layoutSubtreeIfNeeded()
            scroll.contentView.scroll(to: savedScrollOrigin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
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
            refresh: { [weak self] in self?.loadWorkspace(refresh: true) },
            inspect: { [weak self] root in self?.context.onOpenRepository?(root) })
        Deck.pin(list, in: content)
    }

    private func formatFailures(_ failures: [WorkspaceScanFailure]) -> String? {
        guard !failures.isEmpty else { return nil }
        return failures.map { "\($0.root.lastPathComponent): \($0.message)" }.joined(separator: "\n")
    }
}
