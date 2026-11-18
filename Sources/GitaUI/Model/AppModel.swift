import AppKit
import GitaCore

/// One repository tab's model: the repository's snapshot and what the window shows of it. Its parts live in focused
/// value types (`SelectionState`, `HistorySearch`, `BranchFocus`, `HistoryGraphState`, `ProviderState`), a
/// `CommitDraftController` and a `ProviderRefreshScheduler`; the `AppModel+…` files group its features. The state
/// properties are internal so those files can update them; views read the get-only accessors.
@MainActor
final class AppModel {
    enum Change {
        case repository, history, historyAppearance, selection, diff, providers, status, section, activity, commitDraft
    }
    let defaults: UserDefaults
    private var observers: [UUID: (Change) -> Void] = [:]
    var snapshot: RepositorySnapshot? {
        didSet {
            // Counted once per snapshot: menu validation, the action bar and the status item ask on every update.
            conflictCount = snapshot?.conflictCount ?? 0
            updateHasStagedChanges()
        }
    }
    private(set) var conflictCount = 0
    private(set) var hasStagedChanges = false
    /// When Amend Last Commit is armed, Staged shows `diff --cached <base>` (HEAD's parent or empty tree).
    private(set) var amendStaging = AmendStaging.off
    let draftController: CommitDraftController
    var graphState = HistoryGraphState()
    var selection = SelectionState()
    var search = HistorySearch()
    var focus = BranchFocus()
    var providers = ProviderState()
    var gitCaches = GitCacheJobs()
    private var activity = ActivityLog()
    /// The sidebar's pinned, shown-alone and hidden branches for this repository (`BranchFilters`).
    var branchFilters = BranchFilters()
    /// Commits by this author are drawn normally, every other row faded (commit menu › author › Highlight).
    private(set) var highlightedAuthor: CommitAuthor?
    /// An author tab (commit menu › author › Filter): the history is only this author's commits, drawn as a graph of
    /// their own. Set once, before the repository opens.
    var authorLens: CommitAuthor?
    /// The snapshot refresh or history page being read, with its task (`RepositoryRead`).
    var read = RepositoryRead.idle
    var isLoading: Bool { read.isActive }
    var isMutating = false
    /// How the last mutation ended; the toolbar's pill shows it for a moment (`MutationResult.shownFor`).
    var lastMutation: MutationResult?
    /// English for the fixed `RepositoryStatusText` statuses, localized text otherwise (`localizedStatus`).
    private(set) var status = RepositoryStatusText.openRepository.rawValue
    /// The status reports a failure (a refresh, history read, search, clone or initialize failed): the toolbar's
    /// repository pill shows it. Kept beside the text so no caller matches words in a translated status.
    private(set) var statusIsFailure = false
    /// The last read of an older page of the whole history failed: its list offers Retry (`historyPageFailed`).
    /// Unlike `status`, a later refresh does not clear it; the next page read or another history (search, branch,
    /// repository) does. A search and a branch focus keep their own failure with their page read.
    var allHistoryPageFailed = false
    var section: Section = .history {
        didSet { sectionChanged(from: oldValue) }
    }
    var staged = false
    var isWindowVisible = false
    private(set) var isMenuVisible = false
    var isActiveRepository = true
    var service: GitService?
    var root: URL?
    /// Bumped when another repository opens or the model stops: work started for the earlier one never lands.
    private(set) var generation = 0
    private var watcher: RepositoryWatcher?
    private var debounce: Task<Void, Never>?
    /// The working tree changed since the last snapshot read.
    var dirty = false
    var filesystemRevision = 0
    /// `refresh()` was called while a read or a mutation ran: the refresh starts once that ends, however it ends.
    var pendingRefresh = false
    let scheduler = ProviderRefreshScheduler()
    lazy var notificationTracker = ProviderNotificationTracker(viewerLogin: { [weak self] in
        self?.providers.viewerLogin
    })
    let providerService: ProviderService
    let alerts: AlertPresenter
    let dependencies: AppModelDependencies
    private var preferenceObserver: NSObjectProtocol?
    var branchFiltersObserver: NSObjectProtocol?
    private static let debounceDelay = Duration.milliseconds(600)

    /// `providers` runs the provider CLIs and `alerts` shows failures; `dependencies` holds the rest of what the model
    /// reaches outside its repository. Tests pass recording ones.
    init(
        defaults: UserDefaults = AppEnvironment.current.defaults, providers: ProviderService = ProviderService(),
        alerts: AlertPresenter = .shared, dependencies: AppModelDependencies = .standard
    ) {
        self.defaults = defaults
        providerService = providers
        self.alerts = alerts
        self.dependencies = dependencies
        draftController = CommitDraftController(openDraft: dependencies.openCommitDraft)
        draftController.onTextChange = { [weak self] in self?.emit(.commitDraft) }
        draftController.onFailure = { [weak self] failure in
            self?.log(failure.title, failure.message, failed: true)
            if let alert = failure.alert { self?.showError(failure.title, alert) }
        }
        preferenceObserver = NotificationCenter.default.addObserver(
            forName: .gitaPreferenceChanged, object: nil, queue: .main
        ) { [weak self] note in
            let preference = Preference(changed: note)
            MainActor.assumeIsolated { self?.preferenceChanged(preference) }
        }
    }

    isolated deinit {
        for token in [preferenceObserver, branchFiltersObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(token)
        }
    }

    private func preferenceChanged(_ preference: Preference?) {
        switch preference {
        case .squashMergesAsMerges: updateSquashLinks()
        case .collapsesMergedCommits:
            graphState.expandedMerges = []
            relayoutHistory()
        case .showsMergeLabel: emit(.historyAppearance)
        default: if let integration = Integration(switchedBy: preference) { integrationChanged(integration) }
        }
    }

    @discardableResult func observe(_ action: @escaping (Change) -> Void) -> UUID {
        let id = UUID()
        observers[id] = action
        return id
    }
    func removeObserver(_ id: UUID) { observers[id] = nil }
    func emit(_ change: Change) { for observer in Array(observers.values) { observer(change) } }

    var events: [ActivityEvent] { activity.events }
    func log(_ title: String, _ detail: String = "", failed: Bool = false) {
        activity.record(ActivityEvent(title: title, detail: detail, failed: failed))
        emit(.activity)
    }

    /// Shown as a sheet on the repository window, else app-modal: a failure is never only a status line.
    func showError(_ title: String, _ message: String) { alerts.showError(title, message) }

    /// Where the recently opened repositories are kept: each workspace has its own list (`Workspace.recentKey`).
    var recentKey = Preference.recentRepositories.rawValue
    /// Recently opened repositories, read from the preferences each time: every tab has its own model, and a copy kept
    /// here would put back a repository removed from the sidebar's list since.
    var recent: [String] { defaults.stringArray(forKey: recentKey) ?? [] }

    var localizedStatus: String { RepositoryStatusText(rawValue: status)?.localizedTitle ?? status }
    func setStatus(_ text: RepositoryStatusText) { setStatus(text.rawValue, failed: text.isFailure) }
    /// A status of its own (already localized): a mutation's progress or failure, the changed-file count.
    func setStatus(_ text: String, failed: Bool = false) {
        status = text
        statusIsFailure = failed
    }
    /// A read's status. While a mutation runs its own status stays up: the refresh it ends with says how the
    /// repository is after it.
    func setReadStatus(_ text: RepositoryStatusText) { if !isMutating { setStatus(text) } }
    func setReadStatus(_ text: String) { if !isMutating { setStatus(text) } }

    var canStartOperation: Bool { snapshot?.head != nil && snapshot?.operation == nil && !isMutating && !isLoading }
    var hasConflicts: Bool { conflictCount > 0 }

    private func sectionChanged(from oldValue: Section) {
        emit(.section)
        if section == .changes {
            showChanges()
        } else if section == .history, oldValue != .history, focus.isActive, selection.commit == nil,
            selection.stash == nil, let first = focus.commits.first
        {
            select(first)
        }
    }

    /// Starts the repository's timers (and, unless told otherwise, opens `--repository` or the most recent one).
    func start(openInitialRepository: Bool = true) {
        if openInitialRepository,
            let url = AppEnvironment.current.commandLineRepository ?? recent.first.map(URL.init(fileURLWithPath:))
        {
            open(url)
        }
        scheduler.start(
            ProviderRefreshScheduler.Handlers(
                minute: { [weak self] in self?.minuteTick() }, agents: { [weak self] in self?.agentsTick() },
                vercel: { [weak self] in self?.vercelTick() }))
    }

    func open(_ url: URL) {
        guard flushCommitDraft() else { return }
        draftController.reset()
        clearAmendStaging()
        generation += 1
        cancelReads()
        search.clear()
        allHistoryPageFailed = false
        graphState.reset()
        focus.discard()
        focus.allHistorySelection = nil
        selection.clear()
        replaceWatcher(nil)
        snapshot = nil
        providers.reset()
        notificationTracker.reset()
        branchFilters = BranchFilters()
        highlightedAuthor = nil
        root = url.standardizedFileURL
        service = GitService(root: url)
        section = .history
        emit(.repository)
        refresh()
    }

    func stop() {
        generation += 1
        selection.supersede()
        search.invalidate()
        scheduler.stop()
        replaceWatcher(nil)
        isWindowVisible = false
        isMenuVisible = false
        isActiveRepository = false
        cancelReads()
        clearProviderDetails()
        focus.discard()
    }

    private func cancelReads() {
        read.task?.cancel()
        read = .idle
        selection.task?.cancel()
        providers.cancelAll()
        debounce?.cancel()
        debounce = nil
        graphState.cancelSquashSearch()
        graphState.cancelRelayout()
    }

    func repositoryChanged() {
        filesystemRevision += 1
        dirty = true
        guard isObserved, !isMutating else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: Self.debounceDelay)
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    // Keep event-driven Git updates live in a visible window even when the
    // editor has focus. Fast provider polling needs active foreground attention.
    var isObserved: Bool { isWindowVisible || isMenuVisible }
    var isForegroundObserved: Bool { isMenuVisible || (isWindowVisible && NSApp.isActive) }

    func becameVisible() {
        isWindowVisible = true
        refreshVisibleContext()
    }
    func setMenuVisible(_ visible: Bool) {
        guard isMenuVisible != visible else { return }
        isMenuVisible = visible
        applicationActivityChanged()
    }
    func applicationActivityChanged() {
        if isForegroundObserved {
            refreshVisibleContext()
        } else {
            providers.agents.cancel()
        }
    }

    /// The repository's file watcher; the one it replaces stops at once.
    func replaceWatcher(_ next: RepositoryWatcher?) {
        watcher?.stop()
        watcher = next
    }

    func highlightAuthor(_ author: CommitAuthor?) {
        guard author != highlightedAuthor else { return }
        highlightedAuthor = author
        emit(.historyAppearance)
    }

    func setAmendStaging(base: String, head: String, files: [FileChange]) {
        amendStaging = .armed(base: base, head: head, files: files)
        updateHasStagedChanges()
    }

    func clearAmendStaging() {
        amendStaging = .off
        updateHasStagedChanges()
    }

    func applyAmendStaging(_ next: AmendStaging) {
        guard amendStaging.isArmed else { return }
        amendStaging = next
        updateHasStagedChanges()
    }

    private func updateHasStagedChanges() {
        if case .armed(_, _, let files) = amendStaging {
            hasStagedChanges = !files.isEmpty
        } else {
            hasStagedChanges = snapshot?.changes.contains(where: \.isStaged) == true
        }
    }
}
