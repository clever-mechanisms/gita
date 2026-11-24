import AppKit
import GitaCore

/// Settings ▸ Git: how Pull and Merge bring in commits (each choice in a card with an illustration of what it does),
/// Remote Updates (Tier 1 read-only remote checks and opt-in auto-fetch), and repository speed-ups.
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
    private(set) lazy var remoteUpdates = RemoteUpdatesControls(
        adapter: RemoteUpdatesSettingsAdapter(
            defaults: defaults,
            statusSummary: { [environment] in environment.app.remoteUpdatesStatus() },
            onChange: { [environment] in environment.app.preferencesDidChange(false) }))
    private(set) lazy var remoteUpdatesGroup = remoteUpdates.makeGroup()

    override init(environment: SettingsEnvironment) {
        super.init(environment: environment)
        pullMode.addItems(withTitles: GitPullMode.allCases.map(\.localizedTitle))
        pullMode.setAccessibilityIdentifier("settings.pullMode")
        mergeMode.addItems(withTitles: GitMergeMode.allCases.map(\.localizedTitle))
        mergeMode.setAccessibilityIdentifier("settings.mergeMode")
        setGroups([syncCards(), remoteUpdatesGroup, performanceGroup()])
    }

    override func view(for anchor: SettingsAnchor) -> NSView? {
        anchor == .remoteUpdates ? remoteUpdatesGroup : nil
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
        refreshRemoteUpdates()
    }
}
