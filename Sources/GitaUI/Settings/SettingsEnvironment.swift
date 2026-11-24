import AppKit
import GitaCore

/// Everything a Settings pane reads from or changes outside its own controls. The defaults are the live app; tests
/// pass a scratch defaults suite and recording closures, so a pane never touches the real settings, System Settings,
/// the login item or the user's agent configuration.
@MainActor
struct SettingsEnvironment {
    var defaults: UserDefaults = Preference.store
    var app = SettingsAppHooks()
    var look = SettingsLookHooks()
    var system = SettingsSystemHooks()
    var agents = SettingsAgentHooks()
    var accounts = CLIAccountProbe()
}

/// What Settings needs from the app shell. `AppDelegate` is the shell.
@MainActor
protocol SettingsShell: AnyObject {
    /// The active repository's model.
    var model: AppModel { get }
    var isLanguageRestarting: Bool { get }
    var defaults: UserDefaults { get }
    var openRepositoryRoots: [URL] { get }
    func preferencesDidChange(refreshProviders: Bool)
    func restartForLanguage()
}

/// The running app: the active repository model and the shell's own state. Without a shell (`init()`), Settings
/// reads no repository and changes nothing outside its own controls.
@MainActor
struct SettingsAppHooks {
    var activeModel: () -> AppModel? = { nil }
    var isLanguageRestarting: () -> Bool = { false }
    /// Settings that the open windows read on their own schedule changed; `true` also refreshes GitHub and Vercel.
    var preferencesDidChange: (Bool) -> Void = { _ in }
    var restartForLanguage: () -> Void = {}
    var remoteUpdatesStatus: () -> String = {
        String(localized: "Checks remotes while repositories are open.")
    }
}

extension SettingsAppHooks {
    init(shell: any SettingsShell) {
        activeModel = { [weak shell] in shell?.model }
        isLanguageRestarting = { [weak shell] in shell?.isLanguageRestarting == true }
        preferencesDidChange = { [weak shell] in shell?.preferencesDidChange(refreshProviders: $0) }
        restartForLanguage = { [weak shell] in shell?.restartForLanguage() }
        remoteUpdatesStatus = { [weak shell] in
            guard let shell else { return String(localized: "Checks remotes while repositories are open.") }
            return Self.remoteUpdatesStatusText(roots: shell.openRepositoryRoots, defaults: shell.defaults)
        }
    }

    static func remoteUpdatesStatusText(
        roots: [URL], defaults: UserDefaults, monitor: RemoteMonitor = .shared
    ) -> String {
        if !Preference.remoteCheck.bool(defaults) { return RemoteCheckState().statusSummary() }
        let line = monitor.statusLine(for: roots)
        if !line.isEmpty { return line }
        return String(localized: "Checks remotes while repositories are open.")
    }
}

/// Live interface switches: theme, fonts, appearance, graph lines, avatars.
@MainActor
struct SettingsLookHooks {
    var applyTheme: (Theme.Choice) -> Void = { Theme.apply($0) }
    var applyInterfaceFont: (InterfaceFont) -> Void = { InterfaceFont.apply($0) }
    var applyCodeFont: (CodeFont) -> Void = { CodeFont.apply($0) }
    var applyAppearance: (NSAppearance?) -> Void = { NSApp.appearance = $0 }
    var applyGraphLines: (GraphCell.LineStyle) -> Void = { GraphCell.setLineStyle($0) }
    /// A history colour (commits, branches, or the checked-out branch) changed: windows redraw from the new choice.
    var applyHistoryTint: (HistoryTint.Role) -> Void = { _ in HistoryTint.apply() }
    var avatarsChanged: () -> Void = { AvatarStore.shared.preferenceChanged() }
}

/// macOS: apps on disk, URLs, the login item, the app language and notification permission.
@MainActor
struct SettingsSystemHooks {
    var applicationURL: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var loginItem = LoginItemControl()
    var setLanguage: (String?) -> Void = { AppLanguage.setOverride($0) }
    var refreshReviewAgents: () -> Void = { ReviewLauncher.refresh() }
    var authorizeNotifications: () async -> Bool = { await NotificationService.shared.authorize() }
    var sendTestNotification: () async -> Bool = { await NotificationService.shared.sendTest() }
    var bundleIdentifier: String? = Bundle.main.bundleIdentifier
    var addGitHubAccount: () -> Void = { GitHubAccountLogin.openTerminal() }
}

/// Open at Login through `LoginItem`.
@MainActor
struct LoginItemControl {
    var status: () -> LoginItem.Status = { LoginItem.status }
    var setEnabled: (Bool) throws -> Void = { try LoginItem.setEnabled($0) }
    var openSettings: () -> Void = { LoginItem.openSettings() }
    var isRegistered: Bool {
        switch status() {
        case .enabled, .requiresApproval: true
        case .disabled, .unavailable: false
        }
    }
}

/// The coding agents Gita sees and the hooks it installs into their configuration.
@MainActor
struct SettingsAgentHooks {
    var sessions: () -> [AgentSession] = { AgentMonitor.shared.sessions }
    var observe: (@escaping @MainActor ([AgentSession]) -> Void) -> UUID = { AgentMonitor.shared.observe($0) }
    var removeObserver: (UUID) -> Void = { AgentMonitor.shared.removeObserver($0) }
    var hookStatus: (AgentTool) -> AgentMonitor.HookStatus = { AgentMonitor.shared.hookStatus($0) }
    var installHooks: (AgentTool) throws -> Void = { try AgentMonitor.shared.installHooks($0) }
    var removeHooks: (AgentTool) throws -> Void = { try AgentMonitor.shared.removeHooks($0) }
    /// Orca is on this Mac: with the Orca integration on, it reports the agents' states and Gitā needs no hooks.
    var orcaInstalled: () -> Bool = {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: BrandMarks.orca) != nil
    }
}
