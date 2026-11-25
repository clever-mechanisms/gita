import AppKit

/// Settings ▸ About: hosts the shared `AboutContentView` inside the Settings pane chrome.
@MainActor
final class AboutSettingsPane: SettingsPaneContent {
    let contentView: AboutContentView

    init(environment: SettingsEnvironment, configuration: AboutConfiguration? = nil) {
        var resolved = configuration ?? AboutConfiguration()
        resolved.openURL = environment.system.openURL
        contentView = AboutContentView(configuration: resolved)
        super.init(environment: environment)
        setGroups([contentView])
    }

    override func refresh() { contentView.refresh() }
    override func didAppear() { contentView.refresh() }
}
