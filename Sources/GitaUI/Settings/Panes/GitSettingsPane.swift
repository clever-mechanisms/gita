import AppKit
import GitaCore

/// Settings ▸ Git: how Pull and Merge bring in commits (each choice in a card with an illustration of what it does),
/// and the repository speed-ups. How the history looks lives in Settings ▸ History; GitHub's and Vercel's automatic
/// refresh in Integrations.
@MainActor
final class GitSettingsPane: SettingsPaneContent {
    private(set) lazy var speedUp = toggle(
        .speedsUpSlowRepositories, accessibility: String(localized: "Speed up slow repositories"),
        identifier: "settings.speedUpSlowRepositories")
    private(set) lazy var pullMode = SettingsForm.popup(accessibility: String(localized: "Pull")) { [weak self] popup in
        self?.setPullMode(popup.indexOfSelectedItem)
    }
    private(set) lazy var mergeMode = SettingsForm.popup(accessibility: String(localized: "Merge")) {
        [weak self] popup in self?.setMergeMode(popup.indexOfSelectedItem)
    }
    let pullIllustration = SyncIllustrationView(.pull(.fastForwardOnly))
    let mergeIllustration = SyncIllustrationView(.merge(.automatic))

    override init(environment: SettingsEnvironment) {
        super.init(environment: environment)
        pullMode.addItems(withTitles: GitPullMode.allCases.map(\.localizedTitle))
        pullMode.setAccessibilityIdentifier("settings.pullMode")
        mergeMode.addItems(withTitles: GitMergeMode.allCases.map(\.localizedTitle))
        mergeMode.setAccessibilityIdentifier("settings.mergeMode")
        setGroups([syncCards(), performanceGroup()])
    }

    /// The repository speed-ups, explained.
    private func performanceGroup() -> SettingsGroup {
        SettingsGroup(
            String(localized: "Performance"),
            [
                SettingsRow(
                    String(localized: "Speed up slow repositories"), [speedUp],
                    help: String(
                        localized:
                            """
                            When a large repository reads slowly, Gitā writes Git's commit-graph file and \
                            refreshes the index, as “git commit-graph write” and “git update-index \
                            --refresh” do. Your commits and files are not changed.
                            """
                    ))
            ])
    }

    override func didAppear() {
        pullIllustration.start()
        mergeIllustration.start()
    }
    override func didDisappear() {
        pullIllustration.stop()
        mergeIllustration.stop()
    }

    override func refresh() {
        speedUp.setOn(Preference.speedsUpSlowRepositories.bool(defaults))
        refreshSync()
    }
}
