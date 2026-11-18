import AppKit

/// Settings ▸ Menu Bar: what the status item shows.
@MainActor
final class MenuBarSettingsPane: SettingsPaneContent {
    private(set) lazy var workingCount = toggle(
        .menuBarShowsWorkingCount, accessibility: String(localized: "Working agents count"))
    private(set) lazy var attentionDot = toggle(
        .menuBarShowsAttentionDot, accessibility: String(localized: "Attention dot"))

    override init(environment: SettingsEnvironment) {
        super.init(environment: environment)
        setGroups([
            SettingsGroup(
                String(localized: "Icon"),
                [
                    SettingsRow(String(localized: "Working agents count"), [workingCount]),
                    SettingsRow(String(localized: "Attention dot"), [attentionDot]),
                ])
        ])
    }

    override func refresh() {
        workingCount.setOn(Preference.menuBarShowsWorkingCount.bool(defaults))
        attentionDot.setOn(Preference.menuBarShowsAttentionDot.bool(defaults))
    }
}
