import AppKit

@MainActor
private final class CommandCenterWindow: NSWindow {
    var shortcut: ((KeyShortcut) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let pressed = KeyShortcut(event: event), shortcut?(pressed) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class WorkspaceCommandCenterWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    let presenter: WorkspaceCommandCenterPresenter
    private static let sections = NSToolbarItem.Identifier("controlPlane.workspace.tabs")
    private static let refreshID = NSToolbarItem.Identifier("controlPlane.workspace.refresh")
    private let tabs = NSSegmentedControl(
        labels: [
            String(localized: "Changes"), String(localized: "Lockstep Branch"),
            String(localized: "Timeline"),
        ], trackingMode: .selectOne, target: nil, action: nil)
    private let changes: WorkspaceChangesTabView
    private let lockstep: WorkspaceLockstepTabView
    private let timeline: WorkspaceTimelineTabView

    init(title: String, presenter: WorkspaceCommandCenterPresenter) {
        self.presenter = presenter
        changes = WorkspaceChangesTabView(presenter)
        lockstep = WorkspaceLockstepTabView(presenter)
        timeline = WorkspaceTimelineTabView(presenter)
        let window = CommandCenterWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.isReleasedWhenClosed = false
        window.title = String(localized: "Workspace Command Center")
        window.subtitle = title
        window.minSize = NSSize(width: 720, height: 480)
        window.center()
        windowFrameAutosaveName = "GitaWorkspaceCommandCenter"
        window.delegate = self
        window.shortcut = { [weak self] in self?.handleShortcut($0) == true }
        compose(window)
        presenter.changed = { [weak self] in self?.render() }
        if presenter.refresh() == nil { render() }
    }
    required init?(coder _: NSCoder) { nil }

    private func compose(_ window: NSWindow) {
        let root = ThemedBackgroundView()
        window.contentView = root
        for view in [changes, lockstep, timeline] { Style.fill(view, in: root, inset: 16) }
        tabs.target = self
        tabs.action = #selector(selectTab)
        tabs.font = Theme.body
        ControlPlaneViews.identify(tabs, "workspace.tabs", String(localized: "Workspace command center sections"))
        let toolbar = NSToolbar(identifier: "controlPlane.workspace.toolbar")
        toolbar.delegate = self
        toolbar.centeredItemIdentifiers = [Self.sections]
        toolbar.displayMode = .iconOnly
        window.toolbarStyle = .unified
        window.toolbar = toolbar
    }

    func toolbarDefaultItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.sections, .flexibleSpace, Self.refreshID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar _: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case Self.sections:
            item.label = String(localized: "Workspace sections")
            item.view = tabs
        case Self.refreshID:
            item.label = String(localized: "Refresh")
            item.toolTip = ShortcutCommand.refresh.toolTip
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: item.label)
            item.target = self
            item.action = #selector(refresh)
        default: return nil
        }
        return item
    }

    private func handleShortcut(_ pressed: KeyShortcut) -> Bool {
        if pressed == ShortcutStore.shortcut(.refresh) {
            refresh()
            return true
        }
        guard pressed.modifiers == [.command, .control] else { return false }
        switch pressed.key {
        case "1": presenter.select(.changes)
        case "2": presenter.select(.lockstep)
        case "3": presenter.select(.timeline)
        default: return false
        }
        return true
    }

    func windowWillClose(_: Notification) { presenter.cancelAll() }
    @objc private func refresh() { presenter.refresh() }
    @objc private func selectTab() { presenter.select(.init(rawValue: tabs.selectedSegment) ?? .changes) }

    private func render() {
        tabs.selectedSegment = presenter.tab.rawValue
        changes.isHidden = presenter.tab != .changes
        lockstep.isHidden = presenter.tab != .lockstep
        timeline.isHidden = presenter.tab != .timeline
        switch presenter.tab {
        case .changes: changes.render()
        case .lockstep: lockstep.render()
        case .timeline: timeline.render()
        }
    }
}
