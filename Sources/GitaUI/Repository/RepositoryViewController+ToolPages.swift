import AppKit
import GitaCore

/// Parameters for opening an inline per-repository tool page inside `RepositoryViewController`.
enum ToolPageRequest {
    case storage(scope: StorageInlineViewController.Scope = .repository)
    case submodulesLFS(initialTab: SubmodulesLFSPresenter.Tab? = nil)
    case cleanup
    case stackedBranches(baseBranch: String? = nil)
    case reflog(ref: String = "HEAD")
    case codeSearch(initialPattern: String? = nil, pathFilter: String? = nil)
    case lineHistory(range: LineRangeSpec)
    case commitBuckets
    case collisionRadar
    case flightRecorder
    case agentArena(baseCommit: String = "HEAD")
    case visualPreviewDiff(pair: VisualPreviewPair, initialRoute: String = "/")

    var section: Section {
        switch self {
        case .storage: .storage
        case .submodulesLFS: .submodulesLFS
        case .cleanup: .cleanup
        case .stackedBranches: .stackedBranches
        case .reflog: .reflog
        case .codeSearch: .codeSearch
        case .lineHistory: .lineHistory
        case .commitBuckets: .commitBuckets
        case .collisionRadar: .collisionRadar
        case .flightRecorder: .flightRecorder
        case .agentArena: .agentArena
        case .visualPreviewDiff: .visualPreviewDiff
        }
    }
}

/// Container view that forwards keyboard shortcuts to the active inline tool controller (e.g. Commit Buckets).
@MainActor
final class ToolHostView: NSView {
    var onKeyEquivalent: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKeyEquivalent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// Holds the active inline tool child view controller and its return section for one repository tab.
@MainActor
final class RepositoryToolHost {
    let container = ToolHostView()
    var returnSection: Section = .history
    var pendingRequest: ToolPageRequest?
    private(set) var activeSection: Section?
    private(set) var activeController: NSViewController?
    private(set) var activeRootPath: String?
    private(set) weak var activeService: GitService?
    private var retainedArena: (rootPath: String, controller: AgentArenaViewController)?
    private lazy var fallbackStorageStore = StorageStore()
    private lazy var fallbackAgentControl = AgentControlFacade()

    func storageStore(from commands: (any RepositoryCommands)?) -> StorageStore {
        commands?.storageStore ?? fallbackStorageStore
    }

    func agentControl(from commands: (any RepositoryCommands)?) -> AgentControlFacade {
        commands?.agentControlFacade ?? fallbackAgentControl
    }

    func mount(
        _ controller: NSViewController, section: Section, rootPath: String?, service: GitService?,
        in parent: NSViewController
    ) {
        unmount(from: parent, cancelArena: false)
        activeSection = section
        activeController = controller
        activeRootPath = rootPath
        activeService = service
        parent.addChild(controller)
        Style.fill(controller.view, in: container)
        container.onKeyEquivalent = { [weak controller] event in
            (controller as? CommitBucketsViewController)?.handleShortcut(event) ?? false
        }
    }

    func unmount(from _: NSViewController, cancelArena: Bool) {
        container.onKeyEquivalent = nil
        if let active = activeController {
            tearDownController(active, cancelArena: cancelArena)
            active.view.removeFromSuperview()
            active.removeFromParent()
        }
        activeController = nil
        activeSection = nil
        activeRootPath = nil
        activeService = nil
        if cancelArena {
            retainedArena?.controller.presenter.cancelAndCleanup()
            retainedArena = nil
        }
    }

    func reusableArena(for rootPath: String) -> AgentArenaViewController? {
        guard let retainedArena, retainedArena.rootPath == rootPath else { return nil }
        return retainedArena.controller
    }

    func retainArenaIfBusy(_ arena: AgentArenaViewController, rootPath: String?) {
        switch arena.presenter.state {
        case .racing, .comparing, .cancelling, .pickingWinner:
            if let rootPath { retainedArena = (rootPath, arena) }
        default:
            if retainedArena?.controller === arena { retainedArena = nil }
        }
    }

    var hasActiveMutation: Bool {
        switch activeController {
        case let cleanup as CleanupAssistantViewController: cleanup.isCleaning
        case let stacks as BranchStackViewController: stacks.isRestacking
        case let buckets as CommitBucketsViewController: buckets.isCommitting
        default: false
        }
    }

    private func tearDownController(_ controller: NSViewController, cancelArena: Bool) {
        if tearDownGitTool(controller) { return }
        switch controller {
        case let radar as CollisionRadarViewController: radar.presenter.cancel()
        case let flight as AgentFlightRecorderViewController: flight.presenter.cancel()
        case let preview as VisualPreviewDiffViewController: preview.tearDown()
        case let arena as AgentArenaViewController:
            if cancelArena {
                arena.presenter.cancelAndCleanup()
                if retainedArena?.controller === arena { retainedArena = nil }
            } else {
                retainArenaIfBusy(arena, rootPath: activeRootPath)
            }
        default: break
        }
    }

    private func tearDownGitTool(_ controller: NSViewController) -> Bool {
        switch controller {
        case let storage as StorageInlineViewController: storage.cancel()
        case let cleanup as CleanupAssistantViewController: cleanup.cancel()
        case let stacks as BranchStackViewController: stacks.cancel()
        case let submodules as SubmodulesLFSViewController: submodules.cancel()
        case let reflog as ReflogViewController: reflog.cancel()
        case let search as CodeSearchViewController: search.cancel()
        case let lineHistory as LineHistoryViewController: lineHistory.cancel()
        case let buckets as CommitBucketsViewController: buckets.cancel()
        default: return false
        }
        return true
    }
}

/// Inline per-repository tool hosting inside `RepositoryViewController.pagePane`.
extension RepositoryViewController {
    func openToolPage(_ request: ToolPageRequest) {
        if !model.section.isToolPage {
            toolHost.returnSection = request.section == .visualPreviewDiff ? .deployments : model.section
        }
        toolHost.pendingRequest = request
        if model.section == request.section {
            activateToolPage(for: request.section)
        } else {
            model.section = request.section
        }
    }

    func deactivateToolPage() {
        toolHost.unmount(from: self, cancelArena: false)
    }

    func detachToolPages() {
        toolHost.pendingRequest = nil
        toolHost.unmount(from: self, cancelArena: true)
    }

    func reloadInlineStorageIfVisible() {
        (toolHost.activeController as? StorageInlineViewController)?.reloadIfVisible()
    }

    func focusCodeSearchQuery() -> Bool {
        guard let search = toolHost.activeController as? CodeSearchViewController else { return false }
        search.focusQuery()
        return true
    }

    func toolPagesRepositoryChanged() {
        guard toolHost.activeController != nil, isActiveToolStale else { return }
        toolHost.unmount(from: self, cancelArena: true)
        if model.section.isToolPage { model.section = .history }
    }

    private var isActiveToolStale: Bool {
        canonicalPath(model.snapshot?.root) != toolHost.activeRootPath || model.service !== toolHost.activeService
    }

    func activateToolPage(for section: Section) {
        let request = consumeToolRequest(for: section)
        guard let request else {
            model.section = toolReturnTarget()
            return
        }
        if updateActiveToolIfReusable(request) { return }
        guard let controller = makeToolController(for: request) else {
            model.section = toolReturnTarget()
            return
        }
        toolHost.mount(
            controller, section: section, rootPath: canonicalPath(model.snapshot?.root),
            service: model.service, in: self)
        startToolController(controller, for: request)
    }

    private func consumeToolRequest(for section: Section) -> ToolPageRequest? {
        if let pending = toolHost.pendingRequest, pending.section == section {
            toolHost.pendingRequest = nil
            return pending
        }
        return defaultToolRequest(for: section)
    }

    private func defaultToolRequest(for section: Section) -> ToolPageRequest? {
        switch section {
        case .storage: .storage(scope: .repository)
        case .submodulesLFS: .submodulesLFS(initialTab: nil)
        case .cleanup: .cleanup
        case .stackedBranches: .stackedBranches(baseBranch: nil)
        case .reflog: .reflog(ref: "HEAD")
        case .codeSearch: .codeSearch()
        case .commitBuckets: .commitBuckets
        case .collisionRadar: .collisionRadar
        case .flightRecorder: .flightRecorder
        case .agentArena: .agentArena(baseCommit: model.selectedCommit?.id ?? "HEAD")
        case .lineHistory, .visualPreviewDiff: nil
        default: nil
        }
    }

    private func updateActiveToolIfReusable(_ request: ToolPageRequest) -> Bool {
        let currentRoot = canonicalPath(model.snapshot?.root)
        guard toolHost.activeSection == request.section,
            toolHost.activeRootPath == currentRoot,
            toolHost.activeService === model.service,
            let active = toolHost.activeController
        else { return false }
        switch (request, active) {
        case (.storage(let scope), let vc as StorageInlineViewController):
            guard let root = model.snapshot?.root else { return false }
            vc.configure(context: makeStorageContext(for: root), scope: scope)
            return true
        case (.submodulesLFS(let tab), let vc as SubmodulesLFSViewController):
            if let tab { vc.selectTab(tab) }
            vc.loadIfNeeded()
            return true
        case (.stackedBranches(let base), let vc as BranchStackViewController):
            vc.reload(baseBranch: base)
            return true
        case (.reflog(let ref), let vc as ReflogViewController):
            vc.reload(ref: ref)
            return true
        case (.codeSearch(let pattern, let path), let vc as CodeSearchViewController):
            vc.show(initialPattern: pattern, pathFilter: path)
            return true
        case (.lineHistory(let range), let vc as LineHistoryViewController):
            vc.reload(range: range)
            return true
        case (.agentArena(let base), let vc as AgentArenaViewController):
            if vc.presenter.canStart { vc.setup.setBase(base) }
            return true
        default:
            return false
        }
    }

    private func makeToolController(for request: ToolPageRequest) -> NSViewController? {
        switch request {
        case .visualPreviewDiff(let pair, let initialRoute):
            let controller = VisualPreviewDiffViewController(pair: pair, initialRoute: initialRoute)
            controller.onBack = { [weak self] in self?.model.section = .deployments }
            return controller
        case .storage:
            guard model.snapshot?.root != nil else { return nil }
            let controller = StorageInlineViewController(store: toolHost.storageStore(from: commands))
            controller.onOpenWorkspaceStorage = { [weak self] in self?.commands?.openWorkspaceStorage() }
            controller.onOpenGlobalSettings = { SettingsWindowController.shared.show(.git, anchor: .performance) }
            return controller
        case .collisionRadar, .flightRecorder, .agentArena:
            return makeAgentToolController(for: request)
        default:
            return makeGitToolController(for: request)
        }
    }

    private func makeAgentToolController(for request: ToolPageRequest) -> NSViewController? {
        guard let root = model.snapshot?.root else { return nil }
        let facade = toolHost.agentControl(from: commands)
        switch request {
        case .collisionRadar:
            let controller = facade.makeCollisionRadarViewController(for: root)
            controller.onBack = { [weak self] in self?.returnFromToolPage() }
            return controller
        case .flightRecorder:
            let controller = facade.makeFlightRecorderViewController(for: root)
            controller.onBack = { [weak self] in self?.returnFromToolPage() }
            return controller
        case .agentArena(let baseCommit):
            let canonical = canonicalPath(root) ?? root.path
            let controller =
                toolHost.reusableArena(for: canonical)
                ?? facade.makeArenaViewController(for: root, baseCommit: baseCommit)
            if controller.presenter.canStart { controller.setup.setBase(baseCommit) }
            controller.onBack = { [weak self] in self?.returnFromToolPage() }
            return controller
        default:
            return nil
        }
    }

    private func makeGitToolController(for request: ToolPageRequest) -> NSViewController? {
        guard let root = model.snapshot?.root, let service = model.service else { return nil }
        let name = root.lastPathComponent
        switch request {
        case .cleanup:
            let vc = CleanupAssistantViewController(gitService: service, repositoryName: name) { [weak self] in
                self?.model.refresh()
            }
            vc.onBack = { [weak self] in self?.returnFromToolPage() }
            return vc
        case .stackedBranches(let base):
            let vc = BranchStackViewController(gitService: service, baseBranch: base, repositoryName: name) {
                [weak self] in self?.model.refresh()
            }
            vc.onBack = { [weak self] in self?.returnFromToolPage() }
            return vc
        case .submodulesLFS:
            let vc = SubmodulesLFSViewController(
                repositoryRoot: root, service: service,
                onOpenInTab: { [weak self] url in self?.commands?.openRepositoryTab(url) },
                onRevealInFinder: { url in NSWorkspace.shared.activateFileViewerSelecting([url]) })
            vc.onBack = { [weak self] in self?.returnFromToolPage() }
            return vc
        case .reflog:
            let vc = ReflogViewController(service: service, repositoryRoot: root, repositoryName: name)
            vc.onJumpToCommit = { [weak self] sha in self?.showCommit(id: sha) }
            vc.onRepositoryMutated = { [weak self] in self?.model.refresh() }
            vc.onBack = { [weak self] in self?.returnFromToolPage() }
            return vc
        case .codeSearch:
            let vc = CodeSearchViewController(service: service, repositoryRoot: root, repositoryName: name)
            vc.onJumpToCommit = { [weak self] sha in self?.showCommit(id: sha) }
            vc.onBack = { [weak self] in self?.returnFromToolPage() }
            return vc
        case .lineHistory(let range):
            let vc = LineHistoryViewController(service: service, range: range, repositoryRoot: root)
            vc.onJumpToCommit = { [weak self] sha in self?.showCommit(id: sha) }
            vc.onBack = { [weak self] in self?.returnFromToolPage() }
            return vc
        case .commitBuckets:
            let vc = CommitBucketsViewController(gitService: service) { [weak self] _ in self?.model.refresh() }
            vc.onBack = { [weak self] in self?.returnFromToolPage() }
            return vc
        default:
            return nil
        }
    }

    private func startToolController(_ controller: NSViewController, for request: ToolPageRequest) {
        switch (request, controller) {
        case (.storage(let scope), let vc as StorageInlineViewController):
            if let root = model.snapshot?.root { vc.configure(context: makeStorageContext(for: root), scope: scope) }
        case (.cleanup, let vc as CleanupAssistantViewController):
            vc.reload()
        case (.stackedBranches(let base), let vc as BranchStackViewController):
            vc.reload(baseBranch: base)
        case (.submodulesLFS(let tab), let vc as SubmodulesLFSViewController):
            if let tab { vc.selectTab(tab) }
            vc.loadIfNeeded()
        case (.reflog(let ref), let vc as ReflogViewController):
            vc.reload(ref: ref)
        case (.codeSearch(let pattern, let path), let vc as CodeSearchViewController):
            vc.show(initialPattern: pattern, pathFilter: path)
        case (.lineHistory(let range), let vc as LineHistoryViewController):
            vc.reload(range: range)
        default:
            break
        }
    }

    private func makeStorageContext(for root: URL) -> StorageWindowContext {
        commands?.storageContext(for: root) ?? StorageWindowContext(repositoryRoot: root)
    }

    private func returnFromToolPage() {
        model.section = toolReturnTarget()
    }

    private func toolReturnTarget() -> Section {
        toolHost.returnSection.isToolPage ? .history : toolHost.returnSection
    }

    private func canonicalPath(_ url: URL?) -> String? {
        url?.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
