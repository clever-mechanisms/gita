import AppKit
import GitaCore

/// Settings ▸ Git ▸ Pull and Merge: how Pull brings in the upstream's commits and the strategy the Merge sheet opens
/// with, each titled with its "?" above a card holding its pop-up and the `SyncIllustrationView` of what it does.
extension GitSettingsPane {
    func syncCards() -> NSView {
        SettingsForm.sideBySide([
            SettingsChoiceCard(
                String(localized: "Pull"), popup: pullMode,
                help: String(
                    localized:
                        """
                        How the Pull sheet starts; you can still change it there. Fast-forward only never \
                        makes a commit and stops when you have commits the remote lacks. Merge joins both \
                        sides with a merge commit; Rebase replays your commits on top of the remote's.
                        """
                ), illustration: pullIllustration),
            SettingsChoiceCard(
                String(localized: "Merge"), popup: mergeMode,
                help: String(
                    localized:
                        """
                        The strategy the Merge sheet starts with; you can still change it there before \
                        merging.
                        """
                ), illustration: mergeIllustration),
        ])
    }

    func refreshSync() {
        let pull = GitPullMode(rawValue: Preference.pullMode.string(defaults)) ?? .fastForwardOnly
        let merge = GitMergeMode(rawValue: Preference.mergeMode.string(defaults)) ?? .automatic
        pullMode.selectItem(at: GitPullMode.allCases.firstIndex(of: pull) ?? 0)
        mergeMode.selectItem(at: GitMergeMode.allCases.firstIndex(of: merge) ?? 0)
        pullIllustration.show(.pull(pull))
        mergeIllustration.show(.merge(merge))
    }

    func setPullMode(_ index: Int) {
        guard GitPullMode.allCases.indices.contains(index) else { return }
        let mode = GitPullMode.allCases[index]
        Preference.pullMode.set(mode.rawValue, defaults)
        pullIllustration.show(.pull(mode))
    }

    func setMergeMode(_ index: Int) {
        guard GitMergeMode.allCases.indices.contains(index) else { return }
        let mode = GitMergeMode.allCases[index]
        Preference.mergeMode.set(mode.rawValue, defaults)
        mergeIllustration.show(.merge(mode))
    }
}
