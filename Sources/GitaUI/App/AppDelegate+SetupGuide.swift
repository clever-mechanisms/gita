import AppKit

/// The Setup Guide sheet as the shell drives it.
@MainActor
protocol SetupGuidePresenting: AnyObject {
    var window: NSWindow? { get }
    func present(on parent: NSWindow)
    func dismiss()
}

extension SetupGuideController: SetupGuidePresenting {}

/// The Setup Guide while it shows: its sheet, and the choices it started from (only the changed ones are applied).
@MainActor
struct SetupGuideSession {
    let id: UUID
    let original: SetupChoices
    let controller: any SetupGuidePresenting
}

/// The Setup Guide: a sheet on the main window that drafts a few settings and applies only those it changed. While
/// it shows, repository requests and notification results wait.
extension AppDelegate {
    @objc func showSetupGuide() {
        showWindow()
        if let setupGuide {
            setupGuide.controller.window?.makeKeyAndOrderFront(nil)
            return
        }
        presentSetupGuide()
    }

    func presentSetupGuide() {
        guard gate.canPresentSetupGuide, let window = mainWindow else { return }
        loginOffer.hide()
        let choices = SetupChoices(model: model)
        let id = UUID()
        let controller = environment.system.makeSetupGuide(
            SetupGuideRequest(
                choices: choices,
                firstRun: defaults.integer(forKey: SetupGuideState.defaultsKey) < SetupGuideState.version,
                onFinish: { [weak self] choices in self?.finishSetupGuide(id, choices: choices) },
                onCancel: { [weak self] in self?.finishSetupGuide(id, choices: nil) }))
        setupGuide = SetupGuideSession(id: id, original: choices, controller: controller)
        controller.present(on: window)
        windows.validateToolbar()
    }

    /// Closes the guide, applying `choices` (nil when cancelled). `resumeNavigation` is false when quitting: waiting
    /// requests are dropped instead of opened.
    func finishSetupGuide(_ id: UUID, choices: SetupChoices?, resumeNavigation: Bool = true) {
        guard let session = setupGuide, session.id == id else { return }
        if !resumeNavigation {
            // didEndSheet also retries attention requests. Clear them before
            // dismissal so a result/error sheet cannot get ahead of Quit.
            cancelAttentionNavigation()
            _ = router.drain()
        }
        setupGuide = nil
        initialSetupPending = false
        session.controller.dismiss()
        defaults.set(SetupGuideState.version, forKey: SetupGuideState.defaultsKey)
        let refreshProviders = choices.map { apply($0.changes(from: session.original)) } ?? false
        preferencesDidChange(refreshProviders: refreshProviders)
        windows.validateToolbar()
        guard resumeNavigation else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.openPendingURLs()
            self.resumePendingAttention()
            self.loginOffer.update()
        }
    }

    /// Stores the guide's edits; true when provider refresh was turned on. Each switch is stored as Settings stores
    /// it, so what it drives (an integration's reads, agent detection, the history) follows at once.
    private func apply(_ changes: [SetupChoices.Change]) -> Bool {
        var refreshProviders = false
        for change in changes {
            switch change {
            case .historyZoomPercent(let percent): defaults.set(percent, forKey: Preference.historyZoomPercent.rawValue)
            case .setting(let preference, let on):
                preference.set(on, defaults)
                // The guide's one "Refresh automatically" covers GitHub and Vercel; Settings splits them.
                if preference == .providerRefresh {
                    Preference.vercelRefresh.set(on, defaults)
                    refreshProviders = on
                }
            }
        }
        return refreshProviders
    }
}
