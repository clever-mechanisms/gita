import GitaCore

/// The detail pane's tabs under the history.
enum DetailTab: Int, CaseIterable {
    case commit, changes, tree

    var title: String {
        switch self {
        case .commit: String(localized: "Commit")
        case .changes: String(localized: "Changes")
        case .tree: String(localized: "File Tree")
        }
    }
}

/// The detail bar: Commit · Changes · File Tree (or "Local Changes"), the parent choice and the SHA, and which pane
/// shows below it.
struct DetailBarState: Equatable {
    /// The SHA shown in the bar is this long.
    static let shortSHALength = 12

    var tab: DetailTab
    var showsTabs: Bool
    var showsTreeTab: Bool
    var label: String?
    var showsCommitDetail: Bool
    var showsParentChoice: Bool
    /// The selected commit's SHA (copied by the SHA button).
    var sha: String?
    var shortSHA: String? { sha.map { String($0.prefix(Self.shortSHALength)) } }

    /// `tab`: the tab chosen last; a stash has no File Tree, so it shows Changes instead.
    init(tab chosen: DetailTab, isChanges: Bool, commit: GitCommit?, hasStash: Bool) {
        let stash = hasStash && commit == nil
        tab = stash && chosen == .tree ? .changes : chosen
        showsTabs = !isChanges
        showsTreeTab = !stash
        label = isChanges ? String(localized: "Local Changes") : nil
        showsCommitDetail = !isChanges && tab == .commit
        showsParentChoice = !showsCommitDetail && tab != .tree && (commit?.parents.count ?? 0) > 1
        sha = isChanges ? nil : commit?.id
    }

    /// The tab that follows the model's review: History's File Tree and Changes tabs mirror `isTreeReview`.
    static func followingReview(_ tab: DetailTab, isTreeReview: Bool, isHistory: Bool) -> DetailTab {
        guard isHistory, tab != .commit, isTreeReview != (tab == .tree) else { return tab }
        return isTreeReview ? .tree : .changes
    }
}
