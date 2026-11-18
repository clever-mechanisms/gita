/// A sidebar row that opens and closes: a group of the open repository (Worktrees, Branches, Remotes, Tags,
/// Stashes), one remote under Remotes, or a folder of branches.
indirect enum SidebarGroupID: Hashable {
    case worktrees, branches, remotes, tags, stashes
    case remote(String)
    /// A folder (`feature` of feature/x) at `path` inside Branches or a remote.
    case folder(in: Self, path: String)

    /// The key `Preference.sidebarGroups` remembers its open-or-closed state under ("branches", "remote:origin",
    /// "folder:branches:feature"): these spellings are stored, so they never change.
    var persistedKey: String {
        switch self {
        case .worktrees: "worktrees"
        case .branches: "branches"
        case .remotes: "remotes"
        case .tags: "tags"
        case .stashes: "stashes"
        case .remote(let name): "remote:" + name
        case .folder(let group, let path): "folder:" + group.persistedKey + ":" + path
        }
    }
}
