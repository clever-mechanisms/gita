import AppKit

/// The Settings window: a resizable macOS sidebar host listing all 10 panes with live search, preserving every
/// existing `SettingsPaneContent` view and `Preference.settingsPane` persistence.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()
    /// True once `shared` exists (refreshing a Settings window that was never opened needs no controller).
    private(set) static var isCreated = false
    /// The shell's hooks for `shared`: the app delegate sets them at launch, before Settings first opens.
    static var appHooks = SettingsAppHooks()
    convenience init() {
        self.init(environment: SettingsEnvironment(app: Self.appHooks))
        Self.isCreated = true
    }
    init(environment: SettingsEnvironment) {
        self.environment = environment
        super.init(window: nil)
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("SettingsWindowController is built in code") }

    static let width: CGFloat = 860
    static let initialHeight: CGFloat = 580
    static let minSize = NSSize(width: 720, height: 420)
    private static let animationDuration: TimeInterval = 0.16

    private let environment: SettingsEnvironment
    private(set) var pane: SettingsPane = .general
    private var contents: [SettingsPane: SettingsPaneContent] = [:]
    private var observers: [NSObjectProtocol] = []
    private var refreshScheduled = false
    private var gate = SettingsRefreshGate()
    private var defaults: UserDefaults { environment.defaults }

    let sidebarController = SettingsSidebarController()
    private let detailController = SettingsDetailViewController()
    private let splitController = NSSplitViewController()
    private var searchIndex = SettingsSearchIndex()
    private(set) var searchResult = SettingsSearchIndex.Result(
        query: "", matchingPanes: SettingsPane.allCases, matchCounts: [:], highlightedTargets: [:])

    func show(_ pane: SettingsPane? = nil, anchor: SettingsAnchor? = nil) {
        AuxiliaryWindowActivation.show(prepareWindow(pane, anchor: anchor))
    }

    /// Re-reads live state into the visible pane (login item, language restart, settings changed elsewhere).
    func refresh() {
        guard window?.isVisible == true else { return }
        refreshVisiblePane()
    }
    private func refreshVisiblePane() {
        gate.record(defaults)
        contents[pane]?.refresh()
    }

    /// Builds the window and selects the pane without ordering it on screen.
    @discardableResult func prepareWindow(
        _ requested: SettingsPane?, anchor: SettingsAnchor? = nil
    ) -> NSWindow {
        Preference.registerDefaults(in: defaults)
        let window = self.window ?? makeWindow()
        let target = requested ?? SettingsPane(rawValue: Preference.settingsPane.string(defaults)) ?? .general
        startObserving()
        select(target, animated: window.isVisible, anchor: anchor)
        return window
    }

    private func makeWindow() -> NSWindow {
        buildAllPanesForIndex()
        sidebarController.onSelectPane = { [weak self] next in
            guard let self, next != self.pane else { return }
            self.select(next, animated: true)
        }
        sidebarController.onSearchChange = { [weak self] query in
            self?.search(query)
        }

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.canCollapse = false
        sidebarItem.minimumThickness = 185
        sidebarItem.maximumThickness = 270
        let detailItem = NSSplitViewItem(viewController: detailController)
        detailItem.minimumThickness = 500
        splitController.splitView.dividerStyle = .thin
        splitController.addSplitViewItem(sidebarItem)
        splitController.addSplitViewItem(detailItem)

        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: Self.initialHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.contentViewController = splitController
        window.setContentSize(NSSize(width: Self.width, height: Self.initialHeight))
        window.contentMinSize = Self.minSize
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.onFindCommand = { [weak self] in self?.sidebarController.focusSearch() }
        window.center()
        self.window = window
        for content in contents.values { content.window = window }
        return window
    }

    // MARK: Panes & Search

    private func buildAllPanesForIndex() {
        for item in SettingsPane.allCases where contents[item] == nil {
            _ = content(for: item)
        }
    }

    private func content(for pane: SettingsPane) -> SettingsPaneContent {
        if let content = contents[pane] { return content }
        let content = pane.makeContent(environment)
        content.window = window
        content.onLayoutChange = { [weak self, weak content] in
            guard let self, let content else { return }
            self.searchIndex.index(pane: pane, content: content)
            if self.pane == pane, self.searchResult.isActive {
                self.search(self.searchResult.query)
            }
        }
        contents[pane] = content
        searchIndex.index(pane: pane, content: content)
        return content
    }

    func select(_ next: SettingsPane, animated: Bool, anchor: SettingsAnchor? = nil) {
        guard let window else { return }
        let incoming = content(for: next)
        let previous = contents[pane]
        let changed = detailController.currentContent !== incoming
        if changed {
            previous?.didDisappear()
            detailController.show(incoming, pane: next)
        }
        pane = next
        Preference.settingsPane.set(next.rawValue, defaults)
        sidebarController.select(next)
        window.title = next.title
        refreshVisiblePane()
        incoming.didAppear()
        applySearchHighlights(in: incoming, for: next)
        if let anchor, let target = incoming.view(for: anchor) {
            detailController.scrollTo(target)
        } else if changed {
            detailController.scrollToTop()
        }
        fadeInIfNeeded(incoming.view, changed: changed, animated: animated)
    }

    func search(_ query: String) {
        if sidebarController.searchField.stringValue != query {
            sidebarController.searchField.stringValue = query
        }
        let result = searchIndex.search(query)
        searchResult = result
        sidebarController.applySearchResult(result)
        if result.isActive, !result.matchingPanes.contains(pane), let first = result.matchingPanes.first {
            select(first, animated: false)
            return
        }
        if let current = contents[pane] {
            applySearchHighlights(in: current, for: pane)
        }
    }

    private func applySearchHighlights(in content: SettingsPaneContent, for pane: SettingsPane) {
        let targets = searchResult.isActive ? (searchResult.highlightedTargets[pane] ?? []) : []
        SettingsSearchIndex.applyHighlights(targets, in: content.view)
        if let first = targets.first {
            detailController.scrollTo(first)
        }
    }

    private func fadeInIfNeeded(_ view: NSView, changed: Bool, animated: Bool) {
        guard changed, animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            view.alphaValue = 1
            return
        }
        view.alphaValue = 0
        NSAnimationContext.runAnimationGroup {
            $0.duration = Self.animationDuration
            view.animator().alphaValue = 1
        }
    }

    // MARK: Live state

    private func startObserving() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        gate.record(defaults)
        let settingsChanged: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsMayHaveChanged() }
        }
        observers.append(
            center.addObserver(
                forName: UserDefaults.didChangeNotification, object: defaults, queue: .main, using: settingsChanged))
        observers.append(
            center.addObserver(forName: .gitaPreferenceChanged, object: nil, queue: .main, using: settingsChanged))
        observers.append(
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.applicationDidBecomeActive() }
            })
    }
    private func stopObserving() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    /// A defaults write: refreshes only when a value a pane shows changed.
    func settingsMayHaveChanged() {
        if gate.changed(defaults) { scheduleRefresh() }
    }
    /// Back to the front: the login item may have been approved in System Settings, or a CLI signed in.
    func applicationDidBecomeActive() {
        scheduleRefresh()
        contents[pane]?.applicationDidBecomeActive()
    }

    /// Coalesces bursts of preference writes into one refresh of the visible pane.
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refreshVisiblePane()
        }
    }

    func windowDidBecomeKey(_: Notification) { refreshVisiblePane() }
    func windowWillClose(_: Notification) {
        contents[pane]?.didDisappear()
        stopObserving()
        AuxiliaryWindowActivation.closing(window)
    }
}

@MainActor
private final class SettingsWindow: NSWindow {
    var onFindCommand: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
            event.charactersIgnoringModifiers?.lowercased() == "f"
        {
            onFindCommand?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
private final class SettingsDetailViewController: NSViewController {
    private let headerIcon = NSImageView()
    private let headerTitle = SettingsForm.label("", font: TextLines.system(17, weight: .semibold))
    private let scrollView = NSScrollView()
    private let documentView = FlippedView()
    private(set) weak var currentContent: SettingsPaneContent?

    override func loadView() {
        let root = SettingsBackgroundView(frame: NSRect(x: 0, y: 0, width: 640, height: 540))
        view = root

        headerIcon.translatesAutoresizingMaskIntoConstraints = false
        headerIcon.imageScaling = .scaleProportionallyDown
        headerTitle.translatesAutoresizingMaskIntoConstraints = false
        let header = NSStackView(views: [headerIcon, headerTitle])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.edgeInsets = NSEdgeInsets(top: 14, left: 22, bottom: 10, right: 22)
        header.translatesAutoresizingMaskIntoConstraints = false

        let separator = Deck.separator()
        separator.translatesAutoresizingMaskIntoConstraints = false

        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(header)
        root.addSubview(separator)
        root.addSubview(scrollView)
        NSLayoutConstraint.activate([
            headerIcon.widthAnchor.constraint(equalToConstant: 18),
            headerIcon.heightAnchor.constraint(equalToConstant: 18),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.topAnchor.constraint(equalTo: header.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])
    }

    func show(_ content: SettingsPaneContent, pane: SettingsPane) {
        _ = view
        currentContent?.view.removeFromSuperview()
        currentContent = content
        headerIcon.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
        headerIcon.contentTintColor = Theme.secondaryText
        headerTitle.stringValue = pane.title
        documentView.addSubview(content.view)
        NSLayoutConstraint.activate([
            content.view.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            content.view.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            content.view.topAnchor.constraint(equalTo: documentView.topAnchor),
            content.view.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
        ])
    }

    func scrollToTop() {
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func scrollTo(_ target: NSView) {
        view.layoutSubtreeIfNeeded()
        let rect = documentView.convert(target.bounds, from: target)
        documentView.scrollToVisible(rect.insetBy(dx: 0, dy: -12))
    }
}
