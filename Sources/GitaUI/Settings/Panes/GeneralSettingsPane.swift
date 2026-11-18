import AppKit
import GitaCore

/// Settings ▸ General: language, startup, workspaces and the apps Gitā opens. The look lives in Appearance; the AI
/// review in AI Agents.
@MainActor
final class GeneralSettingsPane: SettingsPaneContent {
    private let loginNote = SettingsForm.note()
    private(set) lazy var login = AccentSwitch(accessibility: String(localized: "Open at Login")) { [weak self] _ in
        self?.toggleLogin()
    }
    private lazy var approvalRow: SettingsRow = {
        let approve = SettingsForm.button(
            String(localized: "Approve in System Settings…"), symbol: "arrow.up.forward.app"
        ) { [weak self] in self?.environment.system.loginItem.openSettings() }
        approve.setAccessibilityIdentifier("settings.loginApproval")
        let row = SettingsRow(String(localized: "Approval required"), [approve])
        row.titleLabel.textColor = Theme.needsInputText
        return row
    }()
    private lazy var startupGroup = SettingsGroup(
        String(localized: "Startup"),
        [SettingsRow(String(localized: "Open at Login"), [loginNote, login]), approvalRow])
    /// Off: a workspace chosen from the Workspace menu takes the window's place. On: it opens in its own window.
    private(set) lazy var workspaceWindows = toggle(
        .workspaceWindows, accessibility: String(localized: "Open each workspace in its own window"),
        identifier: "settings.workspaceWindows")
    let language = SettingsForm.popup(accessibility: String(localized: "Language"))
    private(set) lazy var restart = SettingsForm.button(String(localized: "Restart Now"), symbol: "arrow.clockwise") {
        [weak self] in self?.restartForLanguage()
    }
    /// A Git operation starting or ending in the repository in front changes whether Restart Now is offered.
    private lazy var follower = ActiveModelFollower { [weak self] change in
        if change == .status { self?.refreshRestart() }
    }
    let editor = SettingsForm.popup(accessibility: String(localized: "Editor"))
    let terminal = SettingsForm.popup(accessibility: String(localized: "Terminal"))
    let terminalColors = SettingsForm.popup(accessibility: String(localized: "Terminal colours"))
    /// Shows the open panel for "Choose…"; tests answer it directly.
    var chooseApplication: (NSWindow, @escaping (URL?) -> Void) -> Void = { window, done in
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.beginSheetModal(for: window) { response in done(response == .OK ? panel.url : nil) }
    }

    override init(environment: SettingsEnvironment) {
        super.init(environment: environment)
        login.setAccessibilityIdentifier("settings.login")
        restart.setAccessibilityIdentifier("settings.restartLanguage")
        fillLanguage()
        configureOpenWith()
        let languageGroup = SettingsGroup(
            String(localized: "Language"), [SettingsRow(String(localized: "Language"), [restart, language])])
        let workspaces = SettingsGroup(
            String(localized: "Workspaces"),
            [SettingsRow(String(localized: "Open each workspace in its own window"), [workspaceWindows])])
        setGroups([languageGroup, startupGroup, workspaces, openWithGroup()])
    }

    override func didDisappear() { follower.stop() }

    override func refresh() {
        follower.follow(environment.app.activeModel())
        refreshLanguage()
        refreshStartup()
        workspaceWindows.setOn(Preference.workspaceWindows.bool(defaults))
        refreshOpenWith()
    }

    // MARK: Startup

    private func refreshStartup() {
        let status = environment.system.loginItem.status()
        login.setOn(status == .enabled || status == .requiresApproval)
        login.isEnabled = status != .unavailable
        loginNote.stringValue = status == .unavailable ? String(localized: "Unavailable for this copy") : ""
        loginNote.isHidden = status != .unavailable
        let approvalWasHidden = approvalRow.isHidden
        approvalRow.isHidden = status != .requiresApproval
        startupGroup.updateSeparators()
        if approvalWasHidden != approvalRow.isHidden { onLayoutChange?() }
    }
    private func toggleLogin() {
        let loginItem = environment.system.loginItem
        let model = environment.app.activeModel()
        if let model { LoginItem.answerOffer(defaults: model.defaults) }
        do {
            try loginItem.setEnabled(!loginItem.isRegistered)
            model?.log(Self.loginLog(loginItem.status()), failed: loginItem.status() == .unavailable)
        } catch {
            present(error)
        }
        refresh()
        environment.app.preferencesDidChange(false)
    }
    static func loginLog(_ status: LoginItem.Status) -> String {
        switch status {
        case .enabled: String(localized: "Opens at login")
        case .requiresApproval: String(localized: "Login approval required")
        case .disabled: String(localized: "Open at Login disabled")
        case .unavailable: String(localized: "Login item unavailable")
        }
    }

    // MARK: Language

    private func fillLanguage() {
        let system = String(localized: "System (\(AppLanguage.name(of: AppLanguage.system)))")
        language.addItem(AppLanguage.flag(of: nil) + "  " + system, value: nil)
        for code in AppLanguage.available {
            language.addItem(AppLanguage.flag(of: code) + "  " + AppLanguage.name(of: code), value: code)
        }
        language.onChange = { [weak self] popup in
            guard let self else { return }
            self.environment.system.setLanguage(popup.selectedValue)
            self.environment.app.preferencesDidChange(false)
            self.refresh()
        }
        language.setAccessibilityIdentifier("settings.language")
    }
    private func refreshLanguage() {
        let selectedLanguage = AppLanguage.selected.map { language.select(value: $0) } ?? false
        if !selectedLanguage { language.selectItem(at: 0) }
        restart.isHidden = !AppLanguage.needsRestart
        refreshRestart()
    }
    /// Restart Now waits while a restart or a Git operation runs.
    private var canRestart: Bool {
        !environment.app.isLanguageRestarting() && environment.app.activeModel()?.isMutating != true
    }
    private func refreshRestart() { restart.isEnabled = canRestart }
    /// Asks again at the click: the button may not have heard of an operation that started since.
    private func restartForLanguage() {
        guard canRestart else {
            refreshRestart()
            return
        }
        environment.app.restartForLanguage()
    }
}
