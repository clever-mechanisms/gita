import AppKit
import GitaCore

@MainActor
public final class TeleportFacade {
    public let teleportPresenter: TeleportPresenter
    public let triageService: MenuBarTriageService
    public let quickLookController: GitaQuickLookPanelController

    private var triagePresenters: [TriageItem.ID: MenuBarTriagePresenter] = [:]

    public init(runner: any CommandRunning = CommandRunner(), configDirectories: GitHubConfigDirectories = .none) {
        teleportPresenter = TeleportPresenter(resolver: .init(runner: runner))
        triageService = MenuBarTriageService(runner: runner, configDirectories: configDirectories)
        quickLookController = GitaQuickLookPanelController(presenter: .init(loader: .init(runner: runner)))
    }

    public func makeTeleportBannerView() -> TeleportBannerView { .init(presenter: teleportPresenter) }

    public func inspectPaletteInput(_ text: String, repositories: [TeleportRepositoryEntry]) {
        teleportPresenter.inspect(text, repositories: repositories)
    }

    public func handleDeepLink(_ url: URL, repositories: [TeleportRepositoryEntry]) -> Bool {
        guard url.scheme?.lowercased() == "gita", let parsed = TeleportParser.parse(url: url) else { return false }
        teleportPresenter.inspect(parsed, repositories: repositories)
        return true
    }

    public var onTeleport: ((TeleportDestination) -> Void)? {
        get { teleportPresenter.onTeleport }
        set { teleportPresenter.onTeleport = newValue }
    }

    public func makeTriageRowView(
        for item: TriageItem, onJumpToTerminal: ((AgentTerminalJumpTarget) -> Void)? = nil
    )
        -> (view: MenuBarTriageRowView, presenter: MenuBarTriagePresenter)
    {
        let presenter: MenuBarTriagePresenter
        if let cached = triagePresenters[item.id], cached.item == item || cached.state == .running {
            presenter = cached
        } else {
            presenter = MenuBarTriagePresenter(item: item, service: triageService)
            triagePresenters[item.id] = presenter
        }
        presenter.onJumpToTerminal = onJumpToTerminal
        return (MenuBarTriageRowView(presenter: presenter), presenter)
    }

    public func retainTriageItems(_ ids: Set<TriageItem.ID>) {
        triagePresenters = triagePresenters.filter { ids.contains($0.key) || $0.value.state == .running }
    }

    public var isQuickLookVisible: Bool { quickLookController.isVisible }

    public func toggleQuickLook(for target: QuickLookTarget, relativeTo window: NSWindow? = nil) {
        quickLookController.toggle(for: target, relativeTo: window)
    }

    public func updateQuickLookSelection(_ target: QuickLookTarget) { quickLookController.updateSelection(target) }
    public func closeQuickLook() { quickLookController.close() }

    public var onQuickLookNavigate: ((QuickLookNavigationDirection) -> Void)? {
        get { quickLookController.onNavigate }
        set { quickLookController.onNavigate = newValue }
    }

    public var onQuickLookOpenFull: ((QuickLookTarget) -> Void)? {
        get { quickLookController.onOpenFullInMainWindow }
        set { quickLookController.onOpenFullInMainWindow = newValue }
    }
}
