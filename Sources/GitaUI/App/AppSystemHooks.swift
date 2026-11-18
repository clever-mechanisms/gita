import AppKit

/// What the shell does outside its own windows: quitting, opening the replacement app, alerts, the pasteboard,
/// Finder and the browser. The defaults are the live app; tests record them instead.
@MainActor
struct AppSystemHooks {
    typealias ReplacementCompletion = @MainActor (_ failure: String?) -> Void

    var terminate: @MainActor () -> Void = { NSApp.terminate(nil) }
    var beep: @MainActor () -> Void = { NSSound.beep() }
    var activation = ActivationPolicyCoordinator.shared
    var isAppActive: @MainActor () -> Bool = { NSApp.isActive }
    /// The language chosen in Settings differs from the running one.
    var needsLanguageRestart: @MainActor () -> Bool = { AppLanguage.needsRestart }
    var shouldOfferLogin: @MainActor (AppEnvironment) -> Bool = { LoginItem.shouldOffer(environment: $0) }
    /// Turns Open at Login on and reads the resulting status.
    var enableLoginItem: @MainActor () throws -> LoginItem.Status = {
        try LoginItem.setEnabled(true)
        return LoginItem.status
    }
    var openLoginItemSettings: @MainActor () -> Void = { LoginItem.openSettings() }
    var alerts = AlertPresenter.standard
    var pasteboard = NSPasteboard.general
    var openWebPage: @MainActor (URL?) -> Void = { Deck.open($0) }
    var revealInFinder: @MainActor (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    /// The Setup Guide sheet (its checklist looks for the provider CLIs).
    var makeSetupGuide: @MainActor (SetupGuideRequest) -> any SetupGuidePresenting = { request in
        SetupGuideController(
            choices: request.choices, firstRun: request.firstRun, onFinish: request.onFinish,
            onCancel: request.onCancel)
    }
    /// The model of the window's first tab (and of the repository shown while no window is open).
    var makeModel: @MainActor (UserDefaults) -> AppModel = { AppModel(defaults: $0) }
    /// How repository tabs read their repositories and start the agents.
    var tabs = RepositoryTabsEnvironment.live
    /// Whether the process `pid` of this app is still running (a language restart waits for its predecessor).
    var isRunning: @MainActor (_ bundleIdentifier: String, _ pid: Int32) -> Bool = { identifier, pid in
        NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains {
            $0.processIdentifier == pid && !$0.isTerminated
        }
    }
    /// Opens a new instance of the app at `bundle` with `arguments`; the completion gets a failure message or nil.
    var openReplacement:
        @MainActor (_ bundle: URL, _ arguments: [String], _ done: @escaping ReplacementCompletion) -> Void =
            { bundle, arguments, done in
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.createsNewApplicationInstance = true
                configuration.arguments = arguments
                NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { app, error in
                    let failure =
                        error?.localizedDescription
                        ?? (app == nil ? String(localized: "The replacement app could not be opened.") : nil)
                    Task { @MainActor in done(failure) }
                }
            }
}

/// What the shell asks the Setup Guide for: the settings to start from, and where its answer goes.
@MainActor
struct SetupGuideRequest {
    var choices: SetupChoices
    var firstRun: Bool
    var onFinish: @MainActor (SetupChoices) -> Void
    var onCancel: @MainActor () -> Void
}
