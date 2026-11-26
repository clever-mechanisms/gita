import AppKit
import GitaCore

/// Native macOS window managing a repository's Git Submodules and Git LFS status, files, locks, and cache size.
@MainActor
final class SubmodulesLFSWindowController: NSWindowController, NSWindowDelegate {
    private enum Metrics {
        static let defaultSize = NSSize(width: 780, height: 520)
        static let minSize = NSSize(width: 620, height: 380)
        static let headerHeight: CGFloat = 40
    }

    let presenter: SubmodulesLFSPresenter
    var activation = ActivationPolicyCoordinator.shared

    private var tabButtons: [SubmodulesLFSPresenter.Tab: PartsButton] = [:]
    private let refreshButton: PartsButton
    private let busyLabel = Deck.caption("")
    private lazy var submodulesView = SubmodulesTabView(presenter: presenter)
    private lazy var lfsView = LFSTabView(presenter: presenter)

    init(presenter: SubmodulesLFSPresenter) {
        self.presenter = presenter
        refreshButton = PartsButton.quiet(String(localized: "Refresh"), symbol: "arrow.clockwise") {
            presenter.refreshActiveTab()
        }
        super.init(window: nil)
        presenter.onChange = { [weak self] in self?.syncUI() }
    }

    convenience init(
        repositoryRoot: URL,
        service: GitService,
        onOpenInTab: ((URL) -> Void)? = nil,
        onRevealInFinder: ((URL) -> Void)? = nil
    ) {
        let presenter = SubmodulesLFSPresenter(repositoryRoot: repositoryRoot, service: service)
        presenter.onOpenInTab = onOpenInTab
        presenter.onRevealInFinder =
            onRevealInFinder ?? { url in
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        self.init(presenter: presenter)
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    /// Shows the window, brings it forward, and loads the active tab if still idle.
    func show(initialTab: SubmodulesLFSPresenter.Tab? = nil) {
        let window = prepareWindow(initialTab: initialTab)
        AuxiliaryWindowActivation.show(window, coordinator: activation)
        loadIfNeeded()
    }

    /// Builds the window without ordering it on screen (used by headless tests).
    @discardableResult
    func prepareWindow(initialTab: SubmodulesLFSPresenter.Tab? = nil) -> NSWindow {
        let window = self.window ?? makeWindow()
        if let initialTab {
            presenter.selectTab(initialTab)
        }
        syncUI()
        return window
    }

    func windowWillClose(_: Notification) {
        presenter.cancelReads()
        AuxiliaryWindowActivation.closing(window, coordinator: activation)
    }

    private func loadIfNeeded() {
        if presenter.selectedTab == .submodules {
            loadSubmodulesIfIdle()
        } else {
            loadLFSIfIdle()
        }
    }

    private func loadSubmodulesIfIdle() {
        if case .idle = presenter.submoduleState { presenter.loadSubmodules() }
    }

    private func loadLFSIfIdle() {
        if case .idle = presenter.lfsState { presenter.loadLFS() }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Metrics.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.minSize = Metrics.minSize
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.title = String(localized: "Submodules & Git LFS · \(presenter.repositoryName)")

        let root = ThemedBackgroundView()
        window.contentView = root
        layoutWindow(in: root)
        window.center()
        #if !DEBUG
            window.setFrameAutosaveName("Gita.SubmodulesLFSWindow")
        #endif
        self.window = window
        return window
    }

    private func layoutWindow(in root: NSView) {
        let header = buildHeaderBar()
        let divider = Deck.separator()
        let contentHost = NSView()
        Deck.pin(submodulesView, in: contentHost)
        Deck.pin(lfsView, in: contentHost)

        let stack = Deck.vstack([header, divider, contentHost], spacing: 0)
        Deck.pin(stack, in: root)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        header.heightAnchor.constraint(equalToConstant: Metrics.headerHeight).isActive = true
        divider.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        contentHost.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        contentHost.setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    private func buildHeaderBar() -> NSView {
        var tabViews: [NSView] = []
        for tab in SubmodulesLFSPresenter.Tab.allCases {
            let button = PartsButton(
                [
                    .symbol(tab.symbolName, color: Theme.secondaryText, size: 11.5),
                    .text(tab.title, font: Theme.body, color: Theme.secondaryText),
                ],
                background: .hover,
                accessibility: tab.title
            ) { [weak self] in
                self?.presenter.selectTab(tab)
            }
            button.fixedHeight = 26
            button.horizontalPadding = 10
            button.cornerRadius = 6
            button.setAccessibilityIdentifier("submodulesLFS.tab.\(tab.rawValue)")
            tabButtons[tab] = button
            tabViews.append(button)
        }
        refreshButton.setAccessibilityIdentifier("submodulesLFS.refresh")
        let row = Deck.hstack(tabViews + [Deck.spacer(), busyLabel, refreshButton], spacing: 6)
        row.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        let bar = FillView(color: Theme.toolbar)
        Deck.pin(row, in: bar)
        return bar
    }

    private func syncUI() {
        updateTabButtons()
        updateBusyStatus()
        let showingSubmodules = presenter.selectedTab == .submodules
        submodulesView.isHidden = !showingSubmodules
        lfsView.isHidden = showingSubmodules
        submodulesView.reload()
        lfsView.reload()
    }

    private func updateTabButtons() {
        for tab in SubmodulesLFSPresenter.Tab.allCases {
            guard let button = tabButtons[tab] else { continue }
            let isSelected = presenter.selectedTab == tab
            let color = isSelected ? Theme.text : Theme.secondaryText
            var parts: [PartsButton.Part] = [
                .symbol(tab.symbolName, color: isSelected ? Theme.working : Theme.secondaryText, size: 11.5),
                .text(tab.title, font: isSelected ? Theme.bodyEmphasis : Theme.body, color: color),
            ]
            let badge = tab == .submodules ? presenter.submoduleTabBadge : presenter.lfsTabBadge
            if let badge {
                parts.append(.badge(badge, fill: Theme.control, color: Theme.secondaryText))
            }
            button.parts = parts
            button.background = isSelected ? .selected : .hover
            button.setAccessibilityValue(isSelected ? String(localized: "selected") : nil)
        }
    }

    private func updateBusyStatus() {
        let loadingText = String(localized: "Loading…")
        let activeMessage: String? =
            switch presenter.selectedTab {
            case .submodules:
                presenter.submoduleState.activeAction ?? (presenter.submoduleState.isLoading ? loadingText : nil)
            case .lfs:
                presenter.lfsState.activeAction ?? (presenter.lfsState.isLoading ? loadingText : nil)
            }
        busyLabel.stringValue = activeMessage ?? ""
        busyLabel.isHidden = activeMessage == nil
        refreshButton.isEnabled = !presenter.isActiveTabBusy
    }
}
