import AppKit
import GitaCore

/// The app shell: the main window and its repository tabs, the menu bar item, the menus, deep links and the flows
/// that span windows (setup guide, language restart, Open at Login offer, opening a notification's result). Its
/// features live in the `AppDelegate+…` files; everything outside the shell's windows goes through `environment`.
/// Git commands run in each tab's own `RepositoryCommandResponder`.
///
/// A main window shows one workspace (`AppDelegate+Workspaces`). `place` is the window in front, or the one last in
/// front: `windows`, `model`, `tabsController` and the rest of the shell's "main window" state are that window's.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSToolbarItemValidation, NSMenuItemValidation {
    let environment: AppEnvironment
    let updater: AppUpdater
    let router: URLRouter
    let loginOffer = LoginOfferController()
    var workspaces: WorkspaceList
    /// The main windows, open or closed: always one, and one more for each workspace open in a window of its own.
    var places: [WorkspaceWindow]
    /// The main window in front (or last in front).
    var place: WorkspaceWindow
    let workspaceMenu = WorkspaceMenu()
    var launch = LaunchPhase.starting(wantsWindow: false)
    var launchedInBackground = false
    var initialSetupPending = false
    var statusItem: StatusItemController?
    private var observedModel: AppModel?
    private var modelObserver: UUID?
    var observers: [NSObjectProtocol] = []
    var distributedObserver: NSObjectProtocol?
    var languageRestart = LanguageRestart.idle
    var languageRestartTimeouts = LanguageRestart.Timeouts()
    var setupGuide: SetupGuideSession?
    var attention = AttentionNavigation.idle
    /// Each open tab's Git commands (and the resting model's), by model; see `AppDelegate+Commands`.
    var commandResponders: [ObjectIdentifier: RepositoryCommandResponder] = [:]
    /// The open command palette, if any; see `AppDelegate+Palette`.
    var palette: PaletteController?
    /// Open Submodules & Git LFS utility windows keyed by standardized repository root path.
    var submodulesLFSWindows: [String: SubmodulesLFSWindowController] = [:]
    /// Open Branch & Worktree Cleanup windows keyed by standardized repository root path.
    var cleanupWindows: [String: CleanupAssistantWindowController] = [:]
    /// Open Stacked Branches windows keyed by repository root path and base branch.
    var stackWindows: [String: BranchStackWindowController] = [:]
    /// Open Reflog, Code Search, and Line History windows keyed by repository scope.
    var reflogWindows: [String: ReflogWindowController] = [:]
    var codeSearchWindows: [String: CodeSearchWindowController] = [:]
    var lineHistoryWindows: [String: LineHistoryWindowController] = [:]

    init(environment: AppEnvironment = .current, updater: AppUpdater = .shared) {
        self.environment = environment
        self.updater = updater
        router = URLRouter(scheme: environment.urlScheme)
        workspaces = WorkspaceList.restore(from: environment.defaults)
        place = Self.makePlace(workspaces.active, environment: environment, autosaveName: nil)
        places = [place]
        super.init()
        configureWindowCallbacks(place)
        BuiltInTerminal.open = { [weak self] directory, launch in self?.openTerminal(directory, launch: launch) }
        workspaceMenu.items = { [weak self] in self?.workspaceMenuItems() ?? [] }
        configureLoginOffer()
    }

    isolated deinit { deactivateCommands() }

    var defaults: UserDefaults { environment.defaults }
    var openRepositoryRoots: [URL] {
        var seen = Set<String>()
        return places.flatMap(\.models)
            .compactMap { $0.snapshot?.root ?? $0.root }
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
    var windows: MainWindowController { place.windows }
    /// The model shown while the window is closed (and the first tab's when it opens).
    var restingModel: AppModel {
        get { place.restingModel }
        set { place.restingModel = newValue }
    }
    var restingRepository: URL? {
        get { place.restingRepository }
        set { place.restingRepository = newValue }
    }
    var repositorySession: RepositoryTabSession? {
        get { place.session }
        set { place.session = newValue }
    }
    var tabsController: RepositoryTabsController? { windows.tabs }
    var mainWindow: NSWindow? { windows.window }
    /// The selected tab's model, else the resting one.
    var model: AppModel { tabsController.flatMap { !$0.tabs.isEmpty ? $0.selectedModel : nil } ?? restingModel }
    var repositoryController: RepositoryViewController? {
        tabsController.flatMap { !$0.tabs.isEmpty ? $0.selectedController : nil }
    }
    var isLanguageRestarting: Bool { languageRestart.isActive }
    var didFinishLaunching: Bool { launch.isLaunched }
    /// Whether the user may switch, open or close repositories: no tab is busy and no sheet is open.
    var canChangeRepository: Bool { tabsController?.canChangeRepository ?? !model.isMutating }

    /// The shell's state for the "can the user start this now" questions.
    var gate: ShellGate {
        ShellGate(
            isLaunched: didFinishLaunching, isLanguageRestarting: isLanguageRestarting,
            hasSetupGuide: setupGuide != nil,
            hasMainWindow: mainWindow != nil, hasAttachedSheet: mainWindow?.attachedSheet != nil,
            hasReviewSheet: repositoryController?.hasReviewSheet == true,
            isMutating: model.isMutating || tabsController?.isMutating == true, isLoading: model.isLoading,
            hasSnapshot: model.snapshot != nil, hasPendingAttention: attention.pending != nil,
            isAttentionInFlight: attention.task != nil, launchedInBackground: launchedInBackground,
            isWindowInFront: windows.isInFront && environment.system.isAppActive(),
            hasSeenSetupGuide: defaults.integer(forKey: SetupGuideState.defaultsKey) >= SetupGuideState.version)
    }

    // MARK: NSApplicationDelegate

    func applicationDidFinishLaunching(_: Notification) {
        guard environment.arguments.contains(RelaunchTicketStore.argument) else {
            finishLaunching()
            return
        }
        guard let ticket = tickets.pending(arguments: environment.arguments) else {
            environment.system.terminate()
            return
        }
        waitForPredecessor(of: ticket)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { false }

    func applicationWillTerminate(_: Notification) {
        attention.task?.cancel()
        launch.cancel()
        _ = languageRestart.move(to: .idle)
        loginOffer.hide()
        setupGuide?.controller.dismiss()
        setupGuide = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        if let distributedObserver { DistributedNotificationCenter.default().removeObserver(distributedObserver) }
        distributedObserver = nil
        saveSessions()
        deactivateCommands()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let session = setupGuide { finishSetupGuide(session.id, choices: nil, resumeNavigation: false) }
        switch TerminationPolicy(hasReviewSheet: reviewingController != nil, isMutating: isAnyMutating) {
        case .refuseWhileMutating:
            environment.system.beep()
            return refuseTermination()
        case .now:
            return flushAllCommitDrafts() ? .terminateNow : refuseTermination()
        case .askReviewSheet:
            DispatchQueue.main.async {
                self.dismissReviewSheets { allowed in
                    let flushed = allowed && self.flushAllCommitDrafts()
                    if !flushed { _ = self.refuseTermination() }
                    sender.reply(toApplicationShouldTerminate: flushed)
                }
            }
            return .terminateLater
        }
    }

    /// Asks each window's open review sheet in turn whether the app may quit, and closes those that agree;
    /// `done(false)` at the first that refuses.
    func dismissReviewSheets(asked: Set<ObjectIdentifier> = [], _ done: @escaping @MainActor (Bool) -> Void) {
        guard let controller = reviewingController, !asked.contains(ObjectIdentifier(controller)) else {
            done(true)
            return
        }
        controller.requestApplicationTermination { [weak self] allowed in
            guard allowed, let self else {
                done(false)
                return
            }
            controller.dismissReviewsForTermination()
            self.dismissReviewSheets(asked: asked.union([ObjectIdentifier(controller)]), done)
        }
    }

    /// The app stays: a quit for the language restart's replacement is over too.
    private func refuseTermination() -> NSApplication.TerminateReply {
        leaveLanguageHandover()
        return .terminateCancel
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationDidBecomeActive(_: Notification) {
        if didFinishLaunching { model.applicationActivityChanged() }
        refreshSettings()
        loginOffer.update()
    }

    func applicationDidResignActive(_: Notification) {
        statusItem?.closePanel()
        if didFinishLaunching { model.applicationActivityChanged() }
        loginOffer.hide()
    }

    func application(_: NSApplication, open urls: [URL]) {
        if isLanguageRestarting {
            queueDuringLanguageRestart(urls)
            return
        }
        guard didFinishLaunching, setupGuide == nil else {
            router.enqueue(urls)
            return
        }
        for url in urls {
            switch router.route(url) {
            case .window(let section):
                showWindow()
                if let section { model.section = section }
            case .repository(let folder): openRepositoryTab(folder)
            case .ignored: break
            }
        }
    }

    /// Opens the requests that waited (during launch, the setup guide or a language restart).
    func openPendingURLs() {
        let pending = router.drain()
        if !pending.isEmpty { application(NSApp, open: pending) }
    }

    // MARK: The active model

    func observeActiveModel(_ model: AppModel) {
        if observedModel !== model {
            statusItem?.activeModelWillChange()
            attentionSelectionChanged()
        }
        if let modelObserver { observedModel?.removeObserver(modelObserver) }
        observedModel = model
        activateCommands(for: model)
        modelObserver = model.observe { [weak self, weak model] change in
            guard let self, let model, self.model === model else { return }
            self.activeModelChanged(change)
        }
        statusItem?.refresh()
        windows.validateToolbar()
        refreshSettings()
        if ActivityWindowController.isCreated { ActivityWindowController.shared.activeModelChanged(model) }
        statusItem?.activeModelChanged(model)
        loginOffer.update()
    }

    private func activeModelChanged(_ change: AppModel.Change) {
        if change == .repository || change == .status || change == .providers {
            statusItem?.refresh()
            resumePendingAttention()
            loginOffer.update()
        }
        if change == .providers { refreshSettings() }
        if change == .repository || change == .status || change == .selection || change == .providers {
            windows.validateToolbar()
        }
    }

    /// Settings changed that every tab reads (zoom, details, fonts…); `refreshProviders` also reloads GitHub/Vercel.
    func preferencesDidChange(refreshProviders: Bool = false) {
        for place in places {
            if let tabs = place.tabs {
                tabs.refreshSharedPreferences()
            } else {
                place.restingModel.emit(.historyAppearance)
            }
        }
        if refreshProviders { model.refreshProviders() }
        loginOffer.update()
    }

    func flushCommitDrafts() -> Bool { tabsController?.flushCommitDrafts() ?? model.flushCommitDraft() }

    /// Refreshes the Settings window if it was ever opened (it reads the shell's state).
    func refreshSettings() {
        if SettingsWindowController.isCreated { SettingsWindowController.shared.refresh() }
    }
}
