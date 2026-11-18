import AppKit

/// The Settings window: a preference-style toolbar of panes; the window keeps its width and animates its height to
/// each pane. Every control writes through `Preference` (or LoginItem / AppLanguage) and refreshes from live state.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
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

    static let width: CGFloat = 680
    private static let initialHeight: CGFloat = 400
    private static let animationDuration: TimeInterval = 0.2
    private let environment: SettingsEnvironment
    private(set) var pane: SettingsPane = .general
    private var contents: [SettingsPane: SettingsPaneContent] = [:]
    private var observers: [NSObjectProtocol] = []
    private var refreshScheduled = false
    private var gate = SettingsRefreshGate()
    private var defaults: UserDefaults { environment.defaults }

    func show(_ pane: SettingsPane? = nil) {
        AuxiliaryWindowActivation.show(prepareWindow(pane))
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
    @discardableResult func prepareWindow(_ requested: SettingsPane?) -> NSWindow {
        Preference.registerDefaults(in: defaults)
        let window = self.window ?? makeWindow()
        let target = requested ?? SettingsPane(rawValue: Preference.settingsPane.string(defaults)) ?? .general
        startObserving()
        select(target, animated: window.isVisible)
        return window
    }

    private func makeWindow() -> NSWindow {
        let frame = NSRect(x: 0, y: 0, width: Self.width, height: Self.initialHeight)
        let window = NSWindow(
            contentRect: frame, styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: true)
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = SettingsBackgroundView(frame: frame)
        let toolbar = NSToolbar(identifier: "GitaSettings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.center()
        self.window = window
        return window
    }

    // MARK: Panes

    private func content(for pane: SettingsPane) -> SettingsPaneContent {
        if let content = contents[pane] { return content }
        let content = pane.makeContent(environment)
        content.window = window
        content.onLayoutChange = { [weak self, weak content] in
            guard let self, let content, self.contents[self.pane] === content else { return }
            self.fitWindow(animated: self.window?.isVisible == true)
        }
        contents[pane] = content
        return content
    }

    func select(_ next: SettingsPane, animated: Bool) {
        guard let window, let container = window.contentView else { return }
        let incoming = content(for: next)
        let changed = incoming.view.superview !== container
        if changed { swapIn(incoming, replacing: contents[pane], in: container) }
        pane = next
        Preference.settingsPane.set(next.rawValue, defaults)
        window.toolbar?.selectedItemIdentifier = next.itemIdentifier
        window.title = next.title
        refreshVisiblePane()
        incoming.didAppear()
        let fade = changed && animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if fade { incoming.view.alphaValue = 0 }
        fitWindow(animated: animated)
        if fade {
            NSAnimationContext.runAnimationGroup {
                $0.duration = Self.animationDuration
                incoming.view.animator().alphaValue = 1
            }
        }
    }
    private func swapIn(_ incoming: SettingsPaneContent, replacing previous: SettingsPaneContent?, in container: NSView)
    {
        previous?.didDisappear()
        previous?.view.removeFromSuperview()
        container.addSubview(incoming.view)
        NSLayoutConstraint.activate([
            incoming.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            incoming.view.topAnchor.constraint(equalTo: container.topAnchor),
            incoming.view.widthAnchor.constraint(equalToConstant: Self.width),
        ])
    }

    /// Keeps the top edge where it is and resizes to the pane's fitting height, clamped to the screen.
    private func fitWindow(animated: Bool) {
        guard let window, let content = contents[pane] else { return }
        content.view.layoutSubtreeIfNeeded()
        let height = ceil(content.view.fittingSize.height)
        // Titlebar + toolbar height from the live window: `frameRect(forContentRect:)` misses the preference toolbar
        // until it has been laid out, which cut about 18 pt off the bottom of the first pane shown.
        window.toolbar?.validateVisibleItems()
        window.layoutIfNeeded()
        let chrome = max(
            window.frame.height - window.contentLayoutRect.height, window.frameRect(forContentRect: .zero).height)
        let visible = window.isVisible ? (window.screen ?? NSScreen.main)?.visibleFrame : nil
        let frame = Self.fittedFrame(current: window.frame, height: height + chrome, visible: visible)
        guard frame != window.frame else { return }
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.animationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(frame, display: true)
            }
        } else {
            window.setFrame(frame, display: true)
        }
    }
    /// The window frame `height` tall with its top edge kept, inside `visible` when the window is on a screen.
    static func fittedFrame(current: NSRect, height: CGFloat, visible: NSRect?) -> NSRect {
        var frame = NSRect(x: current.minX, y: current.maxY - height, width: width, height: height)
        if let visible {
            frame.origin.y = max(visible.minY, frame.origin.y)
            frame.origin.x = max(visible.minX, min(frame.origin.x, visible.maxX - frame.width))
        }
        return frame
    }

    @objc private func selectToolbarPane(_ sender: NSToolbarItem) {
        guard let next = SettingsPane(itemIdentifier: sender.itemIdentifier), next != pane else { return }
        select(next, animated: true)
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

    // MARK: Toolbar

    func toolbarAllowedItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPane.allCases.map(\.itemIdentifier)
    }
    func toolbarDefaultItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPane.allCases.map(\.itemIdentifier)
    }
    func toolbarSelectableItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsPane.allCases.map(\.itemIdentifier)
    }
    func toolbar(
        _: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar _: Bool
    ) -> NSToolbarItem? {
        guard let pane = SettingsPane(itemIdentifier: identifier) else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = pane.title
        item.paletteLabel = pane.title
        item.toolTip = nil
        item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
        item.target = self
        item.action = #selector(selectToolbarPane(_:))
        return item
    }
}
