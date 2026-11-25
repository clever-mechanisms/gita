import AppKit
import GitaCore

/// One repository tab: sidebar (repositories, checkouts, refs), worktree strip, virtualized history with a Status
/// column, and the Commit / Changes / File Tree detail below. Pull requests and deployments are pages in the same
/// content area; provider details expand in place (no detail windows). Worktrees & Agents is a pane on the right,
/// shown from anywhere (toolbar Agents button).
///
/// The controller binds the model to its parts (`HistoryTableController`, `FilePaneView`, `DetailBarView`…) and
/// forwards their actions; the `RepositoryViewController+…` files group its features.
@MainActor
final class RepositoryViewController: NSViewController {
    let model: AppModel
    /// The app-level actions (tabs, prompts): the app delegate, or what a test records.
    weak var commands: (any RepositoryCommands)?
    /// The target of the buttons and menu items that send the app's own actions (Open, Clone, Switch Branch,
    /// Continue…): `commands` when it is the app; nil otherwise, so they go up the responder chain.
    /// The tabs this view sits in (nil while it stands alone, as in tests).
    weak var tabs: (any RepositoryTabsContext)?
    var observation: UUID?
    var notificationObservations: [NSObjectProtocol] = []
    var workspaceObservation: UUID?

    // MARK: Parts

    let sidebarView: RepositorySidebarView
    let strip = WorktreeStripView()
    let historyTable = HistoryTableController()
    lazy var historyControls = HistoryHeaderController(
        onAllBranches: { [weak self] in self?.showAllBranches() },
        onStopHighlighting: { [weak self] in self?.model.highlightAuthor(nil) })
    let filePane: FilePaneView
    let codePane = CodePaneView()
    let commitDetail = CommitDetailView()
    let detailBar = DetailBarView()
    let operationBar = OperationBarView(commands: nil)
    let commitFooter = CommitFooterView()
    /// Amend Last Commit in Local Changes. The draft message stays put while this is on.
    var amend = CommitAmend.off
    var amendLoad = 0
    /// Paths unstaged from HEAD while Amend was armed, restored to HEAD if Amend is explicitly unchecked.
    var amendUnstagedPaths: Set<String> = []
    var renderedAmendStaging = AmendStaging.off
    let providerPage = ProviderPageView()
    let prWorkspace = PullRequestReviewWorkspaceView()
    let agentsPane = AgentsPaneView()
    let historyMenu = HistoryMenu()
    let historyMenuVercel = HistoryMenuVercel()
    let sheets = ReviewSheetCoordinator()
    let merge = MergeEditorController()
    let simpleScan = SimpleConflictScan()
    let mergedPopover = MergedCommitsPopover()

    // MARK: Layout

    let outerSplit = DeckSplitView()
    let verticalSplit = DeckSplitView()
    /// The file pane beside the code pane (hidden while the Commit tab shows).
    let filesSplit = DeckSplitView()
    let content = NSView()
    let contentBanner = ContentBannerView()
    lazy var bannerHeight = contentBanner.heightAnchor.constraint(equalToConstant: 0)
    var focusedPane: FocusPane?
    let focusRing = PaneFocusRingView()
    var blameView: BlameView?
    let historyPane = NSView()
    let historyTop = NSView()
    let pagePane = NSView()
    let bottom = ThemedBackgroundView()
    let detailBody = NSView()
    let welcome = ThemedBackgroundView()
    lazy var loadMore = Style.button(
        String(localized: "Load more commits"), symbol: "arrow.down", target: self, action: #selector(moreHistory))
    lazy var historyFooterHeight = loadMore.heightAnchor.constraint(equalToConstant: 0)
    lazy var operationHeight = operationBar.heightAnchor.constraint(equalToConstant: 0)
    lazy var stripHeight = strip.heightAnchor.constraint(equalToConstant: RepositoryLayout.stripHeight)

    // MARK: State

    var panes = PaneState()
    /// Model changes are being applied: selection events from the table are not the user's.
    var updating = false
    var detailTab = DetailTab.commit
    /// The page shown last (Settings, Activity… open windows and keep it).
    var lastPageSection = Section.history
    /// The sidebar row chosen for a reference that is not the focused one (cleared by any other navigation).
    var sidebarSelection: SidebarSelection?
    var renderedChanges: [FileChange] = []
    /// Local Changes were shown at least once (`renderedChanges` holds what they showed).
    var hasRenderedChanges = false
    var renderedFilesRevision = -1
    var scrollMemory = HistoryScrollMemory()
    var mergedCache = MergedCommitCache()
    var unpushed = UnpushedCommits()
    var agentsByCommit: [String: [AgentSession]] = [:]
    var lastAutomaticPage: String?
    /// Pending hover-intent prefetch for a Pull Request row (cancelled if the pointer moves off before the dwell).
    var hoverPrefetchTask: DispatchWorkItem?
    /// A reopened conflict to select once the refreshed snapshot lists it.
    var pendingConflictPath: String?
    /// Commit ID navigated to from `BlameView.onSelectCommit` so `showDiff` keeps blame open across that selection.
    var blameNavigatedCommitID: String?
    lazy var detailLoader: ProviderDetailLoader = { [weak self] item, force in
        guard let self, let target = item.target, let root = self.model.snapshot?.root, let service = self.model.service
        else { return nil }
        guard self.model.service === service, self.model.snapshot?.root == root else { return nil }
        return await self.model.providerDetails(for: item, target: target, forceRefresh: force)
    }

    init(model: AppModel, commands: (any RepositoryCommands)? = nil) {
        self.model = model
        self.commands = commands
        sidebarView = RepositorySidebarView(state: .shared(model.defaults))
        filePane = FilePaneView(defaults: model.defaults)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    override func loadView() {
        view = ThemedBackgroundView()
        buildLayout()
        buildHistory()
        wireSidebar()
        wireFileLists()
        wireDetail()
        wireHistoryPower()
        wireHistoryDrag()
        wireMerge()
        wireStrip()
        wireOverview()
        observation = model.observe { [weak self] change in self?.update(change) }
        observeNotifications()
        update(.repository)
        update(.section)
    }

    private func observeNotifications() {
        let center = NotificationCenter.default
        func observe(_ name: Notification.Name, _ action: @escaping @MainActor (RepositoryViewController) -> Void) {
            notificationObservations.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { if let self { action(self) } }
                })
        }
        observe(WindowAgents.didChange) { $0.agentsChanged() }
        observe(.gitaCodeFontChanged) { $0.codeFontChanged() }
        observe(.gitaInterfaceFontChanged) {
            $0.codeFontChanged()
            $0.rebuildSidebar()
        }
        workspaceObservation = WorkspaceMonitor.shared.observe { [weak self] _ in
            guard let self, self.view.window != nil else { return }
            self.rebuildSidebar()
            self.refreshOverview()
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        let wasUpdating = updating
        updating = true
        applyHistoryAppearance()
        agentsChanged()
        updating = wasUpdating
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        positionPanesOnFirstLayout()
        filePane.positionChangesSplit()
        historyTable.fitColumns()
    }

    /// The tab is closing: observers, the scroll watch, review sheets (unless writing) and provider reads stop.
    func detach() {
        historyTable.invalidate()
        mergedPopover.invalidate()
        hoverPrefetchTask?.cancel()
        hoverPrefetchTask = nil
        for token in notificationObservations { NotificationCenter.default.removeObserver(token) }
        notificationObservations = []
        if let workspaceObservation { WorkspaceMonitor.shared.removeObserver(workspaceObservation) }
        workspaceObservation = nil
        merge.cancel()
        simpleScan.cancel()
        model.clearProviderDetails()
        sheets.detach()
        if let observation { model.removeObserver(observation) }
        observation = nil
    }

    // MARK: Review sheets

    var hasReviewSheet: Bool { sheets.hasSheet }
    func requestApplicationTermination(_ reply: @escaping (Bool) -> Void) {
        sheets.requestApplicationTermination(reply)
    }
    func dismissReviewsForTermination() { sheets.dismissForTermination() }
    func closeReviewSheet() -> Bool { sheets.closeSheet() }

    private var sheetLauncher: RepositorySheetLauncher? {
        view.window.map { RepositorySheetLauncher(model: model, coordinator: sheets, window: $0) }
    }
    func reviewReference(_ request: ReferenceReviewRequest) { sheetLauncher?.reviewReference(request) }
    func reviewReset(_ commit: GitCommit) { sheetLauncher?.reviewReset(commit) }
    func reviewInteractiveRebase(after base: GitCommit) { sheetLauncher?.reviewInteractiveRebase(after: base) }
    func manageRemotes() { sheetLauncher?.manageRemotes() }
}
