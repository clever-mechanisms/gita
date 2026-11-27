import AppKit
import GitaCore

/// Embeddable per-repository Storage & Health view controller for `RepositoryViewController`'s inline pane.
@MainActor
final class StorageInlineViewController: NSViewController, StorageContentHost {
    enum Scope: Int {
        case repository
        case health
    }

    let store: StorageStore
    private(set) var context = StorageWindowContext()
    private(set) var scope = Scope.repository

    var onOpenWorkspaceStorage: (() -> Void)?
    var onOpenGlobalSettings: (() -> Void)?
    var hostWindow: NSWindow? { view.window }

    private let headerBar = FillView(color: Theme.toolbar)
    private let content = NSView()
    private let subtitleLabel = Deck.caption("")
    private var observer: UUID?
    private lazy var renderer = StorageContentRenderer(host: self)

    private lazy var selector: ActionSegmentedControl = {
        let control = StorageStyle.scopeSegmentedControl(
            labels: [
                String(localized: "Disk Usage"),
                String(localized: "Health & Maintenance"),
            ],
            symbols: ["internaldrive", "stethoscope"]
        ) { [weak self] index in
            guard let self, let nextScope = Scope(rawValue: index) else { return }
            self.scope = nextScope
            self.loadScope()
        }
        control.setAccessibilityIdentifier("storage.inline.scopeSelector")
        return control
    }()

    private lazy var allRepositoriesButton: PartsButton = {
        let button = StorageStyle.actionButton(
            String(localized: "All Repositories…"), symbol: "square.stack.3d.up", style: .quiet,
            accessibility: String(localized: "All Repositories…")
        ) { [weak self] in
            self?.onOpenWorkspaceStorage?()
        }
        button.setAccessibilityIdentifier("storage.inline.allRepositories")
        return button
    }()

    init(store: StorageStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("StorageInlineViewController is built in code") }

    override func loadView() {
        let rootView = ThemedBackgroundView()
        buildHeaderBar()
        StorageStyle.layoutHeaderChrome(headerBar: headerBar, content: content, in: rootView)
        view = rootView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(
            self, selector: #selector(render), name: .gitaThemeChanged, object: nil)
        render()
    }

    func configure(context: StorageWindowContext, scope: Scope = .repository) {
        self.context = StorageContentRenderer.normalizedContext(context)
        self.scope = scope
        renderer.resetOutline()
        if observer == nil { observer = store.addObserver { [weak self] in self?.render() } }
        loadViewIfNeeded()
        loadScope()
    }

    func cancel() {
        if let observer { store.removeObserver(observer) }
        observer = nil
        store.cancelActiveScans()
    }

    func loadScope(refresh: Bool = false) {
        if let root = context.repositoryRoot {
            if scope == .health {
                store.inspect(root)
            } else {
                store.scanRepository(root, refresh: refresh)
            }
        }
        render()
    }

    func reloadIfVisible() {
        if isViewLoaded, view.window != nil || view.superview != nil {
            loadScope()
        }
    }

    private func buildHeaderBar() {
        let badge = StorageStyle.iconBadge(
            "internaldrive", tint: Theme.accent, boxSize: 28, symbolSize: 13, cornerRadius: 7)
        let titleLabel = Deck.label(String(localized: "Storage & Health"), font: Theme.bodyEmphasis)
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let titleColumn = Deck.vstack([titleLabel, subtitleLabel], spacing: 1)
        let leading = Deck.hstack([badge, titleColumn], spacing: 10)
        leading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        allRepositoriesButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        selector.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = Deck.hstack(
            [leading, Deck.spacer(), selector, Deck.spacer(), allRepositoriesButton], spacing: 12)
        Deck.pin(row, in: headerBar, insets: NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16))
    }

    @objc private func render() {
        guard isViewLoaded else { return }
        headerBar.color = Theme.toolbar
        selector.selectedSegment = scope.rawValue
        let hasRoot = context.repositoryRoot != nil
        selector.setEnabled(hasRoot, forSegment: Scope.repository.rawValue)
        selector.setEnabled(hasRoot, forSegment: Scope.health.rawValue)
        updateHeaderSubtitle()
        renderer.renderPreservingScroll(in: content) {
            renderCurrentScope()
        }
    }

    private func updateHeaderSubtitle() {
        if let root = context.repositoryRoot {
            subtitleLabel.stringValue = root.lastPathComponent
            subtitleLabel.toolTip = root.path
        } else {
            subtitleLabel.stringValue = String(localized: "No repository selected")
            subtitleLabel.toolTip = nil
        }
    }

    private func renderCurrentScope() {
        guard let root = context.repositoryRoot else {
            StorageStyle.pinTopInset(Deck.caption(String(localized: "No repository selected.")), in: content)
            return
        }
        renderer.renderScope(
            root: root, showHealth: scope == .health, in: content, context: context,
            openGlobalSettings: { [weak self] in self?.onOpenGlobalSettings?() })
    }
}
