import AppKit

/// Deep-link targets inside a Settings pane.
enum SettingsAnchor: Hashable {
    case remoteUpdates
}

/// Settings ▸ sidebar panes. Raw values are stored in `Preference.settingsPane`.
enum SettingsPane: String, CaseIterable {
    case general, appearance, history, git, customActions, externalTools, integrations, agents, shortcuts,
        notifications, menuBar, about

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .appearance: String(localized: "Appearance")
        case .history: String(localized: "History")
        case .git: "Git"
        case .customActions: String(localized: "Custom Actions")
        case .externalTools: String(localized: "External Tools")
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
        case .customActions: "bolt.horizontal"
        case .externalTools: "arrow.left.arrow.right.square"
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

    @MainActor func makeContent(_ environment: SettingsEnvironment) -> SettingsPaneContent {
        switch self {
        case .general: GeneralSettingsPane(environment: environment)
        case .appearance: AppearanceSettingsPane(environment: environment)
        case .history: HistorySettingsPane(environment: environment)
        case .git: GitSettingsPane(environment: environment)
        case .customActions: CustomActionsSettingsPane(environment: environment)
        case .externalTools: ExternalToolsSettingsPane(environment: environment)
        case .integrations: IntegrationsSettingsPane(environment: environment)
        case .agents: AgentsSettingsPane(environment: environment)
        case .shortcuts: ShortcutsSettingsPane(environment: environment)
        case .notifications: NotificationSettingsPane(environment: environment)
        case .menuBar: MenuBarSettingsPane(environment: environment)
        case .about: AboutSettingsPane(environment: environment)
        }
    }
}
