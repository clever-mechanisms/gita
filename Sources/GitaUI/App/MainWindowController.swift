import AppKit

/// A main window: its workspace's repository tabs, toolbar and frame. Closing decisions belong to the shell
/// (`shouldClose`); once closed, the window and its tabs are released and the next `show` builds them again.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    static let autosaveName = "Gita.RepositoryWindow"
    private static let initialSize = NSSize(width: 1_440, height: 900)
    private static let initialContentSize = NSSize(width: 1_440, height: 848)
    private static let minimumSize = NSSize(width: 1_000, height: 620)

    /// The window and the tabs it holds, made and released together.
    private struct Open {
        let window: NSWindow
        let tabs: RepositoryTabsController
    }
    private var open: Open?
    var window: NSWindow? { open?.window }
    var tabs: RepositoryTabsController? { open?.tabs }
    /// Release builds remember the frame; development builds always open centered at the initial size.
    private let savesFrame: Bool
    /// Where its frame is remembered: each workspace's own window has its own.
    private let autosaveName: String
    private let activation: ActivationPolicyCoordinator
    /// The toolbar's items, showing this window's selected tab.
    private lazy var toolbarItems = MainToolbar { [weak self] in
        self?.tabs.flatMap { $0.isEmpty ? nil : $0.selectedModel }
    }

    var shouldClose: @MainActor () -> Bool = { true }
    /// The window is closing; its tabs are still there.
    var willClose: @MainActor (NSWindow) -> Void = { _ in }
    /// The window and its tabs are gone.
    var didClose: @MainActor () -> Void = {}
    var occlusionChanged: @MainActor () -> Void = {}
    /// The window came in front of the app's other windows.
    var didBecomeMain: @MainActor () -> Void = {}

    init(
        savesFrame: Bool, activation: ActivationPolicyCoordinator,
        autosaveName: String = MainWindowController.autosaveName
    ) {
        self.savesFrame = savesFrame
        self.autosaveName = autosaveName
        self.activation = activation
    }

    /// Builds the window around `tabs` (when it is not open already). Without a remembered frame it opens centered,
    /// or a step down and right of `neighbor`, another main window.
    func make(_ tabs: RepositoryTabsController, cascadingFrom neighbor: NSWindow? = nil) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.initialSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Gitā"
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.minSize = Self.minimumSize
        window.delegate = self
        window.contentViewController = tabs
        window.setContentSize(Self.initialContentSize)
        let toolbar = NSToolbar(identifier: "GitaDeckToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.centeredItemIdentifiers = MainToolbar.centered
        window.toolbar = toolbar
        window.center()
        let remembered = savesFrame && window.setFrameUsingName(autosaveName)
        if !remembered, let neighbor {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: Self.topLeft(of: neighbor)))
        }
        if savesFrame { window.setFrameAutosaveName(autosaveName) }
        WindowFrameClamp.track(window)
        open = Open(window: window, tabs: tabs)
        return window
    }

    private static func topLeft(of window: NSWindow) -> NSPoint {
        NSPoint(x: window.frame.minX, y: window.frame.maxY)
    }

    /// Another workspace's tabs take the place of the window's (the window keeps its frame).
    func replaceTabs(_ tabs: RepositoryTabsController) {
        guard let window else { return }
        let frame = window.frame
        window.contentViewController = tabs
        window.setFrame(frame, display: true)
        open = Open(window: window, tabs: tabs)
    }

    /// Fits the window on its screen and brings it and the app forward.
    func bringToFront() {
        guard let window else { return }
        WindowFrameClamp.clamp(window)
        activation.windowWillShow()
        window.makeKeyAndOrderFront(nil)
    }

    var isInFront: Bool {
        guard let window else { return false }
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }
    var isShowing: Bool { window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false }

    func validateToolbar() { window?.toolbar?.validateVisibleItems() }

    // MARK: NSWindowDelegate

    func windowShouldClose(_: NSWindow) -> Bool { shouldClose() }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        willClose(closing)
        open = nil
        activation.windowWillClose(closing)
        didClose()
        DispatchQueue.main.async { closing.contentViewController = nil }
    }

    func windowDidBecomeMain(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        didBecomeMain()
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        tabs?.setWindowVisible(isShowing)
        occlusionChanged()
    }

    // MARK: NSToolbarDelegate

    func toolbarAllowedItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] { MainToolbar.allowedItems }
    func toolbarDefaultItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] { MainToolbar.defaultItems }
    func toolbar(
        _: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar _: Bool
    ) -> NSToolbarItem? {
        toolbarItems.item(identifier)
    }
}
