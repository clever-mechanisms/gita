import AppKit
import Foundation
import GitaCore

@testable import GitaUI

/// What the Settings panes asked the app, macOS and the agents to do, recorded instead of done.
@MainActor
final class SettingsRecorder {
    let suiteName = "GitaUITests-" + UUID().uuidString
    let defaults: UserDefaults
    let runs = SettingsRunLog()

    var model: AppModel?
    var languageRestarting = false
    var preferenceChanges: [Bool] = []
    var restarts = 0
    var themes: [Theme.Choice] = []
    var interfaceFonts: [InterfaceFont] = []
    var codeFonts: [CodeFont] = []
    var appearances: [NSAppearance?] = []
    var graphLines: [GraphCell.LineStyle] = []
    var historyTints: [HistoryTint.Role] = []
    var avatarChanges = 0
    var installedApps: [String: URL] = [:]
    var openedURLs: [URL] = []
    var loginStatus: LoginItem.Status = .disabled
    var loginError: Error?
    var loginRequests: [Bool] = []
    var loginSettingsOpened = 0
    var languages: [String?] = []
    var reviewAgentRefreshes = 0
    var notificationAnswer = true
    var testNotificationAnswer = true
    var testNotificationsSent = 0
    var bundleIdentifier: String? = "dev.clevermechanisms.Gita.tests"
    var sessions: [AgentSession] = []
    var agentObservers: [UUID: @MainActor ([AgentSession]) -> Void] = [:]
    var removedObservers: [UUID] = []
    var hookStatuses: [AgentTool: AgentMonitor.HookStatus] = [:]
    var orcaInstalled = false
    var hookError: Error?
    var installedHooks: [AgentTool] = []
    var removedHooks: [AgentTool] = []

    init() {
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
        UITestSupport.bootstrap()
    }

    func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    var environment: SettingsEnvironment {
        SettingsEnvironment(
            defaults: defaults, app: appHooks, look: lookHooks, system: systemHooks, agents: agentHooks,
            accounts: CLIAccountProbe(run: runs.runner))
    }

    private var appHooks: SettingsAppHooks {
        SettingsAppHooks(
            activeModel: { [self] in model },
            isLanguageRestarting: { [self] in languageRestarting },
            preferencesDidChange: { [self] in preferenceChanges.append($0) },
            restartForLanguage: { [self] in restarts += 1 })
    }
    private var lookHooks: SettingsLookHooks {
        SettingsLookHooks(
            applyTheme: { [self] in themes.append($0) },
            applyInterfaceFont: { [self] in interfaceFonts.append($0) },
            applyCodeFont: { [self] in codeFonts.append($0) },
            applyAppearance: { [self] in appearances.append($0) },
            applyGraphLines: { [self] in graphLines.append($0) },
            applyHistoryTint: { [self] in historyTints.append($0) },
            avatarsChanged: { [self] in avatarChanges += 1 })
    }
    private var systemHooks: SettingsSystemHooks {
        let loginItem = LoginItemControl(
            status: { [self] in loginStatus },
            setEnabled: { [self] on in
                loginRequests.append(on)
                if let loginError { throw loginError }
                loginStatus = on ? .enabled : .disabled
            },
            openSettings: { [self] in loginSettingsOpened += 1 })
        return SettingsSystemHooks(
            applicationURL: { [self] in installedApps[$0] },
            openURL: { [self] in openedURLs.append($0) },
            loginItem: loginItem,
            setLanguage: { [self] in languages.append($0) },
            refreshReviewAgents: { [self] in reviewAgentRefreshes += 1 },
            authorizeNotifications: { [notificationAnswer] in notificationAnswer },
            sendTestNotification: { [self] in
                testNotificationsSent += 1
                return testNotificationAnswer
            },
            bundleIdentifier: bundleIdentifier)
    }
    private var agentHooks: SettingsAgentHooks {
        SettingsAgentHooks(
            sessions: { [self] in sessions },
            observe: { [self] observer in
                let id = UUID()
                agentObservers[id] = observer
                return id
            },
            removeObserver: { [self] in
                removedObservers.append($0)
                agentObservers[$0] = nil
            },
            hookStatus: { [self] in hookStatuses[$0] ?? .notInstalled },
            installHooks: { [self] tool in
                if let hookError { throw hookError }
                installedHooks.append(tool)
                hookStatuses[tool] = .installed
            },
            removeHooks: { [self] tool in
                if let hookError { throw hookError }
                removedHooks.append(tool)
                hookStatuses[tool] = .notInstalled
            },
            orcaInstalled: { [self] in orcaInstalled })
    }

    /// A window for panes built on their own: never ordered on screen.
    func window() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 400), styleMask: [.titled], backing: .buffered,
            defer: true)
        window.isReleasedWhenClosed = false
        return window
    }
}

/// The provider CLI invocations of `CLIAccountProbe`, answered from a table instead of running anything.
final class SettingsRunLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    private var answers: [String: Result<CommandResult, CommandError>] = [:]

    func answer(_ executable: String, with result: Result<CommandResult, CommandError>) {
        lock.withLock { answers[executable] = result }
    }
    var executables: [String] { lock.withLock { calls } }

    var runner: CLIAccountProbe.Runner {
        { [self] executable, arguments in
            let answer = lock.withLock {
                calls.append(([executable] + arguments).joined(separator: " "))
                return answers[executable]
            }
            switch answer {
            case .success(let result): return result
            case .failure(let error): throw error
            case nil: throw CommandError.executableNotFound(executable)
            }
        }
    }

    static func output(_ stdout: String, stderr: String = "", exit: Int32 = 0) -> CommandResult {
        CommandResult(stdout: Data(stdout.utf8), stderr: Data(stderr.utf8), exitCode: exit)
    }
}

struct SettingsTestError: Error, LocalizedError {
    var errorDescription: String? { "Settings test failure" }
}

enum SettingsWait {
    /// Yields to the main actor until `condition` holds, for at most a few seconds.
    @MainActor static func until(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(120) // generous: parallel suites keep the main actor busy
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

extension AccentSwitch {
    /// Flips the switch the way a click does.
    @MainActor func settingsPress() { _ = accessibilityPerformPress() }
}

extension ActionPopUpButton {
    /// Chooses the item titled `title` (or at `index`) and sends the popup's action, like a menu choice.
    @MainActor func settingsChoose(_ title: String) {
        selectItem(withTitle: title)
        sendAction(action, to: target)
    }
    @MainActor func settingsChoose(value: String) {
        select(value: value)
        sendAction(action, to: target)
    }
}

extension ActionSegmentedControl {
    @MainActor func settingsChoose(_ segment: Int) {
        selectedSegment = segment
        sendAction(action, to: target)
    }
}
