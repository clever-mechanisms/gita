import AppKit
import GitaCore

/// Launching: the single-instance hand-over, the menus and menu bar item, process-wide services, and the tab
/// session of the workspace last in front (saved, plus the repositories asked for) with the setup guide on a first
/// interactive launch.
extension AppDelegate {
    /// A replacement started for a language restart polls this long for its predecessor to quit.
    private static let predecessorPolls = 150
    private static let predecessorPollInterval = Duration.milliseconds(100)
    /// Agent CLIs found through the login shell's PATH (nvm, mise…) are looked up once, off the launch path.
    private static let reviewLauncherDelay: TimeInterval = 3

    /// The language relaunch hand-over, kept in the app's settings domain.
    var tickets: RelaunchTicketStore { RelaunchTicketStore(defaults: defaults, urlScheme: environment.urlScheme) }

    /// A replacement for a language restart: launches once its predecessor has quit, opening what it queued.
    func waitForPredecessor(of ticket: RelaunchTicket) {
        let terminate = environment.system.terminate
        let tickets = tickets
        let task = Task { [weak self] in
            for _ in 0..<Self.predecessorPolls {
                guard let self, !Task.isCancelled, tickets.isPending(ticket) else { return terminate() }
                if !self.environment.system.isRunning(self.environment.bundleIdentifier, ticket.predecessor) {
                    guard let urls = try? tickets.consume(ticket) else { return terminate() }
                    self.router.enqueue(urls)
                    self.finishLaunching()
                    return
                }
                do { try await Task.sleep(for: Self.predecessorPollInterval) } catch { return }
            }
            terminate()
        }
        launch = .waitingForPredecessor(task, wantsWindow: launch.wantsWindow)
    }

    func finishLaunching() {
        Preference.registerDefaults(in: defaults)
        launchedInBackground = environment.arguments.contains("--background") || LoginItem.wasLaunchedAtLogin
        if environment.startsServices, !environment.isDevelopment, handOverToEarlierInstance() { return }
        observeSystem()
        let menu = MainMenu.build(target: self)
        NSApp.mainMenu = menu
        ShortcutStore.keepApplied(to: menu, defaults)
        SettingsWindowController.appHooks = SettingsAppHooks(shell: self)
        ActivityWindowController.followedModel = { [weak self] in self?.model }
        MainToolbar.host = self
        statusItem = StatusItemController(
            statusItem: environment.statusBar.statusItem(withLength: NSStatusItem.variableLength),
            host: self, defaults: defaults, updater: updater)
        if environment.startsServices { startServices() }
        NSApp.appearance = AppearanceChoice(stored: Preference.appearance.int(defaults)).appearance
        observeActiveModel(model)
        applyLaunchPlan()
        model.start(openInitialRepository: false)
        if let restingRepository { model.open(restingRepository) }
        let wantsWindow = launch.wantsWindow
        launch = .launched
        let pending = router.drain()
        if !launchedInBackground || wantsWindow || !pending.isEmpty { showWindow() }
        if !pending.isEmpty { application(NSApp, open: pending) }
        resumePendingAttention()
    }

    /// One Gita per session: a second launch hands its repositories to the earlier one and quits.
    private func handOverToEarlierInstance() -> Bool {
        guard let other = SingleInstance.earlierInstance(bundleIdentifier: environment.bundleIdentifier) else {
            return false
        }
        let paths =
            (environment.commandLineRepository.map { [$0.path] } ?? []) + router.pending.filter(\.isFileURL).map(\.path)
        SingleInstance.handOver(paths: paths, to: other, background: launchedInBackground)
        environment.system.terminate()
        return true
    }

    private func startServices() {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.reviewLauncherDelay) { ReviewLauncher.refresh() }
        distributedObserver = SingleInstance.observe { [weak self] folders in
            guard let self else { return }
            if folders.isEmpty {
                self.showWindow()
            } else {
                for folder in folders { self.openRepositoryTab(folder) }
            }
        }
        let notifications = NotificationService.shared
        notifications.configure(
            defaults: defaults, onOpen: { [weak self] in self?.openNotification($0) },
            onFailure: { [weak self] message in
                self?.model.log(String(localized: "Notifications unavailable"), message, failed: true)
            })
        notifications.resolveOpenURL = { Self.deploymentURL(for: $0) }
        notifications.onShowRepository = { [weak self] url in self?.openRepositoryTab(url) }
        AgentMonitor.shared.start()
        updater.start(environment: environment)
    }

    /// A deployment notification opens the deployment's current main URL (production domain or branch preview).
    private static func deploymentURL(for destination: ProviderNotificationDestination) -> URL? {
        guard case .deployment = destination.target,
            let report = ProviderActivity.shared.entry(for: URL(fileURLWithPath: destination.repositoryPath))?
                .reports[.vercel],
            report.sourceID == destination.providerSourceID, let context = report.vercel,
            let item = report.items.first(where: { $0.id == destination.itemID })
        else { return nil }
        return context.primaryURL(for: item)
    }

    /// The System theme follows the accent colour live; sheets pause the login offer and resume a waiting result.
    private func observeSystem() {
        let center = NotificationCenter.default
        observers += [
            center.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    if Theme.palettes[Theme.current]?.followsSystemAccent == true { Theme.refreshAllWindows() }
                }
            },
            center.addObserver(forName: NSWindow.didEndSheetNotification, object: nil, queue: .main) {
                [weak self] _ in
                DispatchQueue.main.async {
                    self?.resumePendingAttention()
                    self?.loginOffer.update()
                }
            },
            center.addObserver(forName: NSWindow.willBeginSheetNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.loginOffer.hide() }
            },
        ]
    }

    /// The tab session to open, and whether the setup guide is due.
    private func applyLaunchPlan() {
        let workspace = place.workspace
        let saved = RepositoryTabSession.restore(from: defaults, key: workspace.sessionKey)
        let plan = LaunchPlan(
            LaunchPlan.Inputs(
                arguments: environment.arguments, isDevelopment: environment.isDevelopment,
                background: launchedInBackground, pendingURLs: router.pending,
                commandLineRepository: environment.commandLineRepository, saved: saved,
                hasStoredSession: [workspace.sessionKey, WorkspaceList.defaultsKey].contains {
                    defaults.object(forKey: $0) != nil
                },
                recent: workspace.recent(in: defaults),
                storedGuideVersion: defaults.object(forKey: SetupGuideState.defaultsKey) as? Int))
        if plan.marksGuideSeen { defaults.set(SetupGuideState.version, forKey: SetupGuideState.defaultsKey) }
        initialSetupPending = plan.initialSetupPending
        repositorySession = plan.session
        plan.session.save(to: defaults, key: workspace.sessionKey)
        restingRepository = plan.session.selectedRepository
    }
}
