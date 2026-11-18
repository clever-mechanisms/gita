import AppKit
import Foundation
import GitaCore
import Testing

@testable import GitaUI

/// The app shell built for a test: a scratch settings domain, a private status bar, recorded alerts and recorded
/// system effects (quitting, the replacement launch, the pasteboard, Finder, the browser, the login item).
@MainActor
final class AppShellRecorder {
    let alerts = AppRecordingAlerts()
    let drafts = FileManager.default.temporaryDirectory.appendingPathComponent("GitaUITests-App-\(UUID())")
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("GitaUITests.App.\(UUID().uuidString)"))
    private(set) var terminations = 0
    private(set) var beeps = 0
    private(set) var policies: [NSApplication.ActivationPolicy] = []
    private(set) var replacements: [[String]] = []
    private(set) var replacementDone: AppSystemHooks.ReplacementCompletion?
    private(set) var revealed: [URL] = []
    private(set) var webPages: [URL?] = []
    private(set) var tabAlerts: [NSAlert] = []
    private(set) var loginSettingsOpened = 0
    var isActive = true
    var needsRestart = true
    var offersLogin = false
    var predecessorRunning = false
    var loginResult: Result<LoginItem.Status, Error> = .success(.enabled)
    private(set) var guides: [AppFakeSetupGuide] = []

    deinit { try? FileManager.default.removeItem(at: drafts) }

    func hooks() -> AppSystemHooks {
        var hooks = AppSystemHooks()
        hooks.terminate = { [weak self] in self?.terminations += 1 }
        hooks.beep = { [weak self] in self?.beeps += 1 }
        hooks.activation = ActivationPolicyCoordinator(
            setPolicy: { [weak self] in self?.policies.append($0) }, activate: {}, windows: { [] })
        hooks.isAppActive = { [weak self] in self?.isActive ?? false }
        hooks.needsLanguageRestart = { [weak self] in self?.needsRestart ?? false }
        hooks.shouldOfferLogin = { [weak self] _ in self?.offersLogin ?? false }
        hooks.enableLoginItem = { [weak self] in try self?.loginResult.get() ?? .disabled }
        hooks.openLoginItemSettings = { [weak self] in self?.loginSettingsOpened += 1 }
        hooks.alerts = alerts.presenter
        hooks.pasteboard = pasteboard
        hooks.openWebPage = { [weak self] in self?.webPages.append($0) }
        hooks.revealInFinder = { [weak self] in self?.revealed.append($0) }
        hooks.isRunning = { [weak self] _, _ in self?.predecessorRunning ?? false }
        hooks.openReplacement = { [weak self] _, arguments, done in
            self?.replacements.append(arguments)
            self?.replacementDone = done
        }
        hooks.makeSetupGuide = { [weak self] request in
            let guide = AppFakeSetupGuide(request)
            self?.guides.append(guide)
            return guide
        }
        let alerts = alerts.presenter
        let drafts = drafts
        hooks.makeModel = { AppModel.appTestModel(defaults: $0, alerts: alerts, drafts: drafts) }
        hooks.tabs = RepositoryTabsEnvironment(
            openRepository: { model, url in model.open(url) }, startAgents: {}, collapsesLeftGroups: { false },
            markSeen: { _ in },
            presentAlert: { [weak self] alert, _, _ in self?.tabAlerts.append(alert) })
        return hooks
    }
}

/// The shell under test and what it did.
@MainActor
final class AppShellHarness {
    let settings: AppTestDefaults
    let recorder = AppShellRecorder()
    let app: AppDelegate

    var defaults: UserDefaults { settings.defaults }
    var alerts: AppRecordingAlerts { recorder.alerts }

    /// `settings`: a settings domain filled before the launch (a fresh one otherwise).
    init(
        arguments: [String] = ["Gita"], isDevelopment: Bool = true, settings: AppTestDefaults = AppTestDefaults()
    ) {
        self.settings = settings
        UITestSupport.bootstrap()
        var environment = AppEnvironment(
            isDevelopment: isDevelopment, defaults: settings.defaults, arguments: arguments, bundle: .main,
            startsServices: false, statusBar: NSStatusBar())
        environment.system = recorder.hooks()
        app = AppDelegate(environment: environment)
        app.loginOffer.delay = .zero
    }

    /// Launches and waits for the repository's first snapshot.
    func launch(waitingFor root: URL? = nil) async {
        app.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        guard let root else { return }
        await appWaitUntil { [app] in
            app.model.snapshot.map { AttentionRequest.sameLocation($0.root, root) } == true
                && !app.model.isLoading
        }
    }

    /// Waits until the selected tab's Git action ended.
    func settle() async {
        await appWaitUntil { [app] in !app.model.isMutating && !app.model.isLoading }
    }

    /// Closes the main windows and the menu bar item: the shell is gone when the test ends.
    func tearDown() {
        app.statusItem?.closePanel()
        for window in app.places.compactMap(\.windows.window) {
            window.attachedSheet.map { window.endSheet($0) }
            window.close()
        }
        app.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        app.statusItem = nil
    }

    func menuItem(_ action: Selector) -> NSMenuItem? {
        Self.items(in: NSApp.mainMenu).first { $0.action == action }
    }

    static func items(in menu: NSMenu?) -> [NSMenuItem] {
        (menu?.items ?? []).flatMap { [$0] + items(in: $0.submenu) }
    }
}

/// A Setup Guide that shows nothing and answers when the test says so.
@MainActor
final class AppFakeSetupGuide: SetupGuidePresenting {
    let request: SetupGuideRequest
    let window: NSWindow? = nil
    private(set) var presentedOn: NSWindow?
    private(set) var dismissed = false

    init(_ request: SetupGuideRequest) { self.request = request }

    func present(on parent: NSWindow) { presentedOn = parent }
    func dismiss() { dismissed = true }
}
