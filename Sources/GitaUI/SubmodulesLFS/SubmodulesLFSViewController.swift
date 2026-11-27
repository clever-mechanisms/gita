import AppKit
import GitaCore

/// Embeddable view controller managing a repository's Git Submodules and Git LFS status, files, locks, and cache.
@MainActor
final class SubmodulesLFSViewController: NSViewController {
    private enum Metrics {
        static let horizontalInset: CGFloat = 18
        static let spinnerSize: CGFloat = 14
    }

    let presenter: SubmodulesLFSPresenter

    private(set) lazy var backButton: PartsButton = WorkflowPageView.makeBackButton(identifier: "submodulesLFS.back") {
        [weak self] in
        self?.onBack?()
    }
    var onBack: (() -> Void)? {
        didSet { backButton.isHidden = onBack == nil }
    }

    private let headerBar = FillView(color: Theme.toolbar)
    private var tabButtons: [SubmodulesLFSPresenter.Tab: PartsButton] = [:]
    private let refreshButton: PartsButton
    private let busySpinner = NSProgressIndicator()
    private let busyLabel = Deck.caption("")
    private lazy var submodulesView = SubmodulesTabView(presenter: presenter)
    private lazy var lfsView = LFSTabView(presenter: presenter)
    private var themeObserver: NSObjectProtocol?

    init(presenter: SubmodulesLFSPresenter) {
        self.presenter = presenter
        refreshButton = PartsButton.quiet(String(localized: "Refresh"), symbol: "arrow.clockwise") {
            presenter.refreshActiveTab()
        }
        refreshButton.fixedHeight = 26
        refreshButton.setAccessibilityIdentifier("submodulesLFS.refresh")
        super.init(nibName: nil, bundle: nil)
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

    isolated deinit {
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
        themeObserver = nil
    }

    override func loadView() {
        let root = ThemedBackgroundView()
        layoutContent(in: root)
        view = root
        observeTheme()
        syncUI()
    }

    func selectTab(_ tab: SubmodulesLFSPresenter.Tab) {
        presenter.selectTab(tab)
        if isViewLoaded { syncUI() }
    }

    func loadIfNeeded() {
        if presenter.selectedTab == .submodules {
            if case .idle = presenter.submoduleState { presenter.loadSubmodules() }
        } else if case .idle = presenter.lfsState {
            presenter.loadLFS()
        }
    }

    func cancel() {
        presenter.cancelReads()
    }

    private func layoutContent(in root: NSView) {
        let header = buildHeaderBar()
        let divider = Deck.separator()
        let contentHost = NSView()
        Deck.pin(submodulesView, in: contentHost)
        Deck.pin(lfsView, in: contentHost)

        let stack = Deck.vstack([header, divider, contentHost], spacing: 0)
        Deck.pin(stack, in: root)
        for item in [header, divider, contentHost] {
            item.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        contentHost.setContentHuggingPriority(.defaultLow, for: .vertical)
        contentHost.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }

    private func buildHeaderBar() -> NSView {
        backButton.isHidden = onBack == nil
        let badge = StorageStyle.iconBadge(
            "shippingbox", tint: Theme.accent, boxSize: 32, symbolSize: 15, cornerRadius: 8)
        let titleLabel = Deck.label(
            String(localized: "Submodules & Git LFS"), font: TextLines.system(14, weight: .semibold), color: Theme.text)
        let subtitle = Deck.caption(presenter.repositoryName)
        let titles = Deck.vstack([titleLabel, subtitle], spacing: 2)

        let tabs = makeTabSwitcher()
        configureBusyIndicator()
        let trailing = Deck.hstack([busySpinner, busyLabel, refreshButton], spacing: 8)

        let row = Deck.hstack([backButton, badge, titles, Deck.spacer(), tabs, trailing], spacing: 10)
        Deck.pin(
            row, in: headerBar,
            insets: NSEdgeInsets(top: 12, left: Metrics.horizontalInset, bottom: 12, right: Metrics.horizontalInset))
        return headerBar
    }

    private func makeTabSwitcher() -> NSStackView {
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
        return Deck.hstack(tabViews, spacing: 4)
    }

    private func configureBusyIndicator() {
        busySpinner.style = .spinning
        busySpinner.controlSize = .small
        busySpinner.usesThreadedAnimation = false
        busySpinner.isDisplayedWhenStopped = false
        busySpinner.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            busySpinner.widthAnchor.constraint(equalToConstant: Metrics.spinnerSize),
            busySpinner.heightAnchor.constraint(equalToConstant: Metrics.spinnerSize),
        ])
    }

    private func observeTheme() {
        themeObserver = NotificationCenter.default.addObserver(
            forName: .gitaThemeChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyTheme() }
        }
    }

    private func applyTheme() {
        headerBar.color = Theme.toolbar
        updateTabButtons()
        submodulesView.applyTheme()
        lfsView.applyTheme()
    }

    private func syncUI() {
        guard isViewLoaded else { return }
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
                parts.append(.badge(badge, fill: isSelected ? Theme.window : Theme.control, color: color))
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
        busySpinner.isHidden = activeMessage == nil
        if activeMessage != nil { busySpinner.startAnimation(nil) } else { busySpinner.stopAnimation(nil) }
        refreshButton.isEnabled = !presenter.isActiveTabBusy
    }
}
