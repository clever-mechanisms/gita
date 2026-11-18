import AppKit
import GitaCore

/// Fetch: one remote, or all of them.
@MainActor
final class FetchSheet: SyncSheet<String?> {
    let remote: NSPopUpButton
    let all = SyncForm.checkbox(String(localized: "Fetch all remotes"))
    private let remotes: [String]

    init(choices: SyncChoices) {
        remotes = choices.remotes
        remote = SyncForm.popUp(
            remotes, symbol: SyncForm.remoteSymbol, label: String(localized: "Remote"))
        if let preferred = choices.preferredRemote { remote.selectItem(at: remotes.firstIndex(of: preferred) ?? 0) }
        all.state = .on
        remote.isEnabled = false
        super.init(title: String(localized: "Fetch"), button: String(localized: "Fetch"))
        all.target = self
        all.action = #selector(allChanged)
        build(
            message: String(localized: "Fetch the latest changes from remotes"),
            rows: [.init(label: String(localized: "Remote:"), view: remote), .init(view: all)])
    }

    @objc func allChanged() { remote.isEnabled = all.state != .on }

    /// nil fetches every remote.
    override var choice: String?? {
        if all.state == .on { return .some(nil) }
        return remotes.indices.contains(remote.indexOfSelectedItem) ? remotes[remote.indexOfSelectedItem] : nil
    }
}

/// Pull: a branch of a remote into the checked-out branch, fast-forwarded, merged or rebased (Settings ▸ Git's Pull
/// mode first), local changes kept aside or not.
@MainActor
final class PullSheet: SyncSheet<GitPullRequest> {
    let remote: NSPopUpButton
    let branch: NSPopUpButton
    let mode: NSPopUpButton
    let autostash = SyncForm.checkbox(String(localized: "Stash and reapply local changes"))
    private let choices: SyncChoices
    private var branches: [String] = []

    init(choices: SyncChoices, into current: String) {
        self.choices = choices
        remote = SyncForm.popUp(
            choices.remotes, symbol: SyncForm.remoteSymbol, label: String(localized: "Remote"))
        branch = SyncForm.popUp(
            [], symbol: SyncForm.branchSymbol, label: String(localized: "Branch"))
        mode = SyncForm.popUp(
            GitPullMode.allCases.map(\.localizedTitle), label: String(localized: "Pull mode"))
        let preferred = GitPullMode(rawValue: Preference.pullMode.string()) ?? .fastForwardOnly
        mode.selectItem(at: GitPullMode.allCases.firstIndex(of: preferred) ?? 0)
        super.init(title: String(localized: "Pull"), button: String(localized: "Pull"))
        remote.target = self
        remote.action = #selector(remoteChanged)
        build(
            message: String(localized: "Pull remote changes and bring them into your local branch"),
            rows: [
                .init(label: String(localized: "Remote:"), view: remote),
                .init(label: String(localized: "Branch:"), view: branch),
                .init(label: String(localized: "Into:"), view: SyncForm.branchLabel(current)),
                .init(label: String(localized: "How:"), view: mode), .init(view: autostash),
            ])
        let target = choices.pullTarget
        if let target, let index = choices.remotes.firstIndex(of: target.remote) { remote.selectItem(at: index) }
        showBranches(selecting: target?.branch)
    }

    @objc func remoteChanged() { showBranches(selecting: nil) }

    private func showBranches(selecting preferred: String?) {
        let index = remote.indexOfSelectedItem
        branches = choices.remotes.indices.contains(index) ? choices.branches(on: choices.remotes[index]) : []
        SyncForm.fill(branch, branches, symbol: SyncForm.branchSymbol)
        let names = [preferred, choices.current, "main", "master"].compactMap { $0 }
        if let name = names.first(where: branches.contains), let at = branches.firstIndex(of: name) {
            branch.selectItem(at: at)
        }
        defaultButton.isEnabled = !branches.isEmpty
    }

    override var choice: GitPullRequest? {
        let remoteIndex = remote.indexOfSelectedItem
        let branchIndex = branch.indexOfSelectedItem
        guard choices.remotes.indices.contains(remoteIndex), branches.indices.contains(branchIndex) else { return nil }
        return GitPullRequest(
            remote: choices.remotes[remoteIndex], branch: branches[branchIndex],
            mode: GitPullMode.allCases[max(0, mode.indexOfSelectedItem)], autostash: autostash.state == .on)
    }
}

/// Push: a local branch to its upstream or another remote branch, with every tag or forced.
@MainActor
final class PushSheet: SyncSheet<GitPushRequest> {
    let branch: NSPopUpButton
    let target: NSPopUpButton
    let tags = SyncForm.checkbox(String(localized: "Push all tags"))
    let force = SyncForm.checkbox(String(localized: "Force push"))
    private let choices: SyncChoices
    private var targets: [SyncTarget] = []

    init(choices: SyncChoices, branch selected: String?) {
        self.choices = choices
        branch = SyncForm.popUp(
            choices.branches, symbol: SyncForm.branchSymbol, label: String(localized: "Branch"))
        target = SyncForm.popUp(
            [], symbol: SyncForm.branchSymbol, label: String(localized: "To"))
        super.init(title: String(localized: "Push"), button: String(localized: "Push"))
        branch.target = self
        branch.action = #selector(branchChanged)
        force.target = self
        force.action = #selector(forceChanged)
        build(
            message: String(localized: "Push your local changes to a remote"),
            rows: [
                .init(label: String(localized: "Branch:"), view: branch),
                .init(label: String(localized: "To:"), view: target), .init(view: tags), .init(view: force),
            ])
        if let selected, let index = choices.branches.firstIndex(of: selected) { branch.selectItem(at: index) }
        branchChanged()
    }

    @objc func branchChanged() {
        let index = branch.indexOfSelectedItem
        targets = choices.branches.indices.contains(index) ? choices.pushTargets(for: choices.branches[index]) : []
        SyncForm.fill(target, targets.map(\.title), symbol: SyncForm.branchSymbol)
        defaultButton.isEnabled = !targets.isEmpty
    }

    /// A forced push is marked destructive, as it can drop commits from the remote.
    @objc func forceChanged() { defaultButton.hasDestructiveAction = force.state == .on }

    override var choice: GitPushRequest? {
        let branchIndex = branch.indexOfSelectedItem
        let targetIndex = target.indexOfSelectedItem
        guard choices.branches.indices.contains(branchIndex), targets.indices.contains(targetIndex) else { return nil }
        let destination = targets[targetIndex]
        return GitPushRequest(
            branch: choices.branches[branchIndex], remote: destination.remote, remoteBranch: destination.branch,
            tags: tags.state == .on, force: force.state == .on)
    }
}
