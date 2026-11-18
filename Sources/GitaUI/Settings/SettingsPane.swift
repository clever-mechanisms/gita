import AppKit

/// Settings ▸ toolbar panes. Raw values are stored in `Preference.settingsPane`.
enum SettingsPane: String, CaseIterable {
    case general, appearance, history, git, integrations, agents, shortcuts, notifications, menuBar, about

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .appearance: String(localized: "Appearance")
        case .history: String(localized: "History")
        case .git: "Git"
        case .integrations: String(localized: "Integrations")
        case .agents: String(localized: "AI Agents")
        case .shortcuts: String(localized: "Shortcuts")
        case .notifications: String(localized: "Notifications")
        case .menuBar: String(localized: "Menu Bar")
        case .about: String(localized: "About")
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        case .history: "point.3.connected.trianglepath.dotted"
        case .git: "arrow.triangle.branch"
        case .integrations: "puzzlepiece.extension"
        case .agents: Self.agentsSymbol
        case .shortcuts: "keyboard"
        case .notifications: "bell.badge"
        case .menuBar: "menubar.rectangle"
        case .about: "info.circle"
        }
    }
    /// AI Agents' symbol, also before the coding-agent groups elsewhere in Settings.
    static let agentsSymbol = "sparkles"
    var itemIdentifier: NSToolbarItem.Identifier { NSToolbarItem.Identifier("settings." + rawValue) }
    init?(itemIdentifier: NSToolbarItem.Identifier) {
        guard let pane = Self.allCases.first(where: { $0.itemIdentifier == itemIdentifier }) else { return nil }
        self = pane
    }

    @MainActor func makeContent(_ environment: SettingsEnvironment) -> SettingsPaneContent {
        switch self {
        case .general: GeneralSettingsPane(environment: environment)
        case .appearance: AppearanceSettingsPane(environment: environment)
        case .history: HistorySettingsPane(environment: environment)
        case .git: GitSettingsPane(environment: environment)
        case .integrations: IntegrationsSettingsPane(environment: environment)
        case .agents: AgentsSettingsPane(environment: environment)
        case .shortcuts: ShortcutsSettingsPane(environment: environment)
        case .notifications: NotificationSettingsPane(environment: environment)
        case .menuBar: MenuBarSettingsPane(environment: environment)
        case .about: AboutSettingsPane(environment: environment)
        }
    }
}
