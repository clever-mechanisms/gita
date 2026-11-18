import AppKit
import GitaCore

/// Settings ▸ History: how the history is drawn, and how merges show, each merge setting in a card with an
/// illustration that plays it. Pull, Merge and the repository speed-ups live in Settings ▸ Git.
@MainActor
final class HistorySettingsPane: SettingsPaneContent {
    /// `Preference.mergedCommitsOn` values in segment order.
    static let mergedCommitsTriggers = ["click", "hover"]

    let size = SettingsForm.popup(accessibility: String(localized: "History size"))
    private(set) lazy var details = AccentSwitch(accessibility: String(localized: "Show commit details")) {
        [weak self] on in self?.setDetails(on)
    }
    private(set) lazy var avatars = AccentSwitch(accessibility: String(localized: "Show GitHub avatars")) {
        [weak self] on in self?.setAvatars(on)
    }
    private(set) lazy var mergeLabel = AccentSwitch(
        accessibility: String(localized: "Show a merge label in history")
    ) { [weak self] on in self?.setMergeLabel(on) }
    private(set) lazy var mergedCommits = SettingsForm.segmented(
        [String(localized: "Click"), String(localized: "Hover")],
        accessibility: String(localized: "Show a merge's commits on")
    ) { [weak self] segment in self?.setMergedCommits(segment) }
    private(set) lazy var graphLines = SettingsForm.segmented(
        [String(localized: "Rounded"), String(localized: "Angled")], accessibility: String(localized: "Graph lines")
    ) { [weak self] segment in self?.setGraphLines(segment) }
    private(set) lazy var collapseMerged = AccentSwitch(accessibility: MergeIllustrationView.Kind.collapse.title) {
        [weak self] on in self?.setMergeSetting(.collapsesMergedCommits, on)
    }
    private(set) lazy var squashMerges = AccentSwitch(accessibility: MergeIllustrationView.Kind.squash.title) {
        [weak self] on in self?.setMergeSetting(.squashMergesAsMerges, on)
    }
    let collapseIllustration = MergeIllustrationView(.collapse, isOn: true)
    let squashIllustration = MergeIllustrationView(.squash, isOn: true)

    override init(environment: SettingsEnvironment) {
        super.init(environment: environment)
        mergedCommits.setAccessibilityIdentifier("settings.mergedCommits")
        graphLines.setAccessibilityIdentifier("settings.graphLines")
        collapseMerged.setAccessibilityIdentifier("settings.collapseMergedCommits")
        squashMerges.setAccessibilityIdentifier("settings.squashMerges")
        for percent in HistoryZoom.all {
            size.addItem(withTitle: String(localized: "\(percent)%"))
            size.lastItem?.tag = percent
        }
        size.onChange = { [weak self] popup in self?.setSize(popup.selectedItem?.tag) }
        size.setAccessibilityIdentifier("settings.historySize")
        details.setAccessibilityIdentifier("settings.historyDetails")
        avatars.setAccessibilityIdentifier("settings.avatars")
        mergeLabel.setAccessibilityIdentifier("settings.showMergeLabel")
        setGroups([historyGroup(), mergesGroup(), mergeCards()])
    }

    /// Size, lines, details and avatars.
    private func historyGroup() -> SettingsGroup {
        SettingsGroup(
            String(localized: "History"),
            [
                SettingsRow(String(localized: "Size"), [size]),
                SettingsRow(String(localized: "Graph lines"), [graphLines]),
                SettingsRow(String(localized: "Show commit details"), [details]),
                SettingsRow(String(localized: "Show GitHub avatars"), [avatars]),
            ])
    }

    /// How a merge's label shows and how its commits open.
    private func mergesGroup() -> SettingsGroup {
        SettingsGroup(
            String(localized: "Merges"),
            [
                SettingsRow(String(localized: "Show a merge label in history"), [mergeLabel]),
                SettingsRow(
                    String(localized: "Show a merge's commits on"), [mergedCommits],
                    help: String(
                        localized:
                            """
                            A merge's chip lists the commits it brought in. Choose whether the list opens \
                            when you click the chip or as soon as the pointer rests on it.
                            """
                    )),
            ])
    }

    /// How merges fold and how squash merges draw: each switch in a card with its illustration, side by side.
    private func mergeCards() -> NSView {
        SettingsForm.sideBySide(
            [
                SettingsFeatureCard(
                    MergeIllustrationView.Kind.collapse.title, control: collapseMerged,
                    help: String(
                        localized:
                            """
                            On, a merge's row stands for every commit it brought in, so the history shows \
                            one row per merge. Open the merge's chip to see its commits.
                            """
                    ), illustration: collapseIllustration),
                SettingsFeatureCard(
                    MergeIllustrationView.Kind.squash.title, control: squashMerges,
                    help: String(
                        localized:
                            """
                            A squash merge lands as one ordinary commit, so its branch looks unmerged. On, \
                            Gitā draws the branch joining its squash commit, like a merge.
                            """
                    ), illustration: squashIllustration),
            ])
    }

    override func didAppear() {
        collapseIllustration.start()
        squashIllustration.start()
    }
    override func didDisappear() {
        collapseIllustration.stop()
        squashIllustration.stop()
    }

    override func refresh() {
        size.selectItem(withTag: HistoryZoom.shown(Preference.historyZoomPercent.int(defaults)))
        details.setOn(Preference.showsHistoryDetails.bool(defaults))
        avatars.setOn(Preference.showsAvatars.bool(defaults))
        mergeLabel.setOn(Preference.showsMergeLabel.bool(defaults))
        squashMerges.setOn(Preference.squashMergesAsMerges.bool(defaults))
        collapseMerged.setOn(Preference.collapsesMergedCommits.bool(defaults))
        mergedCommits.selectedSegment =
            Self.mergedCommitsTriggers.firstIndex(of: Preference.mergedCommitsOn.string(defaults)) ?? 0
        let style = GraphCell.LineStyle(rawValue: Preference.graphLines.string(defaults)) ?? .rounded
        graphLines.selectedSegment = GraphCell.LineStyle.allCases.firstIndex(of: style) ?? 0
        // Still pictures hold the current setting; playing ones keep their loop.
        if !collapseIllustration.plays { collapseIllustration.show(collapseMerged.isOn) }
        if !squashIllustration.plays { squashIllustration.show(squashMerges.isOn) }
    }

    /// Stores a merge setting and turns its illustration to match.
    private func setMergeSetting(_ preference: Preference, _ on: Bool) {
        preference.set(on, defaults)
        (preference == .collapsesMergedCommits ? collapseIllustration : squashIllustration).show(on)
    }
    private func setGraphLines(_ segment: Int) {
        guard GraphCell.LineStyle.allCases.indices.contains(segment) else { return }
        environment.look.applyGraphLines(GraphCell.LineStyle.allCases[segment])
    }
    private func setMergedCommits(_ segment: Int) {
        guard Self.mergedCommitsTriggers.indices.contains(segment) else { return }
        Preference.mergedCommitsOn.set(Self.mergedCommitsTriggers[segment], defaults)
    }
    private func setSize(_ value: Int?) {
        guard let value, HistoryZoom.range.contains(value) else { return }
        Preference.historyZoomPercent.set(value, defaults)
        environment.app.preferencesDidChange(false)
    }
    private func setDetails(_ on: Bool) {
        Preference.showsHistoryDetails.set(on, defaults)
        environment.app.preferencesDidChange(false)
    }
    private func setAvatars(_ on: Bool) {
        Preference.showsAvatars.set(on, defaults)
        environment.look.avatarsChanged()
        if on { environment.app.preferencesDidChange(true) }
    }
    private func setMergeLabel(_ on: Bool) {
        Preference.showsMergeLabel.set(on, defaults)
        environment.app.preferencesDidChange(false)
    }
}
