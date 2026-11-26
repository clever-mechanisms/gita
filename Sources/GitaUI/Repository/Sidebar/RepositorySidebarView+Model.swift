import AppKit
import GitaCore

/// What the sidebar lists: its input from the repository window and the rows built from it.
extension RepositorySidebarView {
    struct Checkout: Equatable {
        var path: String
        var branch: String
        var sessions: [AgentSession]
        var meta: String
        var isMain: Bool
        var isLocked = false
        /// The checkout is being opened (its tab is reading the repository): a spinner replaces the meta.
        var isLoading = false
        /// Exact commits behind upstream (after fetch).
        var behind = 0
        /// Tier 1 remote check saw upstream moved before objects were fetched (`RemoteMonitor`).
        var remoteMoved = false

        var remoteUpdateText: String {
            if behind > 0, remoteMoved { return "↓\(behind) ⇣" }
            if behind > 0 { return "↓\(behind)" }
            if remoteMoved { return "⇣" }
            return ""
        }

        var remoteUpdateToolTip: String? {
            if remoteMoved, behind > 0 {
                return String(localized: "\(behind) commits behind upstream; remote has un-fetched commits")
            }
            if remoteMoved { return String(localized: "Remote has un-fetched commits") }
            if behind > 0 { return String(localized: "\(behind) commits behind upstream") }
            return nil
        }
    }

    struct Repository: Equatable {
        var root: URL
        var name: String
        var badge: String
        var badgeIsChange: Bool
        var isCurrent: Bool
        var checkouts: [Checkout]
        var error: String?
        var behind = 0
        var remoteMoved = false
        /// Most recently used checkout path for this repository, when known.
        var mruCheckoutPath: String?

        /// The checkout opened when clicking this repository row: MRU checkout if available, else main, else first,
        /// else repository root.
        var primaryCheckoutURL: URL {
            if let mruCheckoutPath,
                let match = checkouts.first(where: {
                    RecentRepositories.canonical($0.path) == RecentRepositories.canonical(mruCheckoutPath)
                })
            {
                return URL(fileURLWithPath: match.path, isDirectory: true)
            }
            if let main = checkouts.first(where: \.isMain) ?? checkouts.first {
                return URL(fileURLWithPath: main.path, isDirectory: true)
            }
            return root
        }
    }

    struct Input: Equatable {
        var repositories: [Repository] = []
        var currentName = ""
        var currentRoot: URL?
        var references: [GitReference] = []
        var stashes: [GitStash] = []
        var remotes: [String] = []
        var changes = 0
        var pullRequests = 0
        var workflows = 0 // running or queued workflow runs
        var deployments = 0
        /// The integrations switched on: GitHub lists Pull Requests and Workflows, Vercel Deployments.
        var showsGitHub = true
        var showsVercel = true
        var selection = SidebarSelection.history
        var branchAgents: [String: AgentMarkState] = [:]
        /// Unresolved Vercel preview comments per branch.
        var branchComments: [String: Int] = [:]
        var productionBranch: String?
        var filters = BranchFilters()
        /// Branches checked out in a linked worktree (short name → its path): listed under Worktrees, not Branches.
        var worktreeBranches: [String: String] = [:]
        /// Each remote's URL by name: its host's mark stands beside it.
        var remoteURLs: [String: String] = [:]
        /// Configured remote names resolved as GitHub (including SSH host aliases).
        var githubRemotes: Set<String> = []
        /// Up to 5 recently checked out branch names from the local reflog.
        var recentBranches: [String] = []
        /// Cached formatted disk footprint for the repository, when scanned.
        var storageSize: String?
    }

    /// A branch row's filter marks and, in the Worktrees group, the worktree's folder.
    struct Marks: Equatable {
        var pinned = false
        var only = false
        var hidden = false
        /// Branches (local and remote) take the pin / show-only / hide buttons; tags do not.
        var filterable = false
        /// The current branch stays in the graph (HEAD is always walked): no hide button.
        var hideable = false
        var worktree: String?
        /// Folder depth inside Branches or a remote (feature/x sits one level in, under "feature").
        var depth = 0
        /// The name shown when the row sits in a folder (its last part).
        var label: String?
    }

    /// A group row's chevron: nil when the group has nothing to open.
    enum Expansion: Equatable {
        case none, collapsed, expanded

        init(expanded: Bool) { self = expanded ? .expanded : .collapsed }
    }

    /// A navigation row: a page (Local Changes, Pull Requests…) or a group that opens onto a list.
    struct Nav: Equatable {
        /// A page the row opens, or a group it opens and closes.
        enum Target: Equatable {
            case page(SidebarSelection)
            case group(SidebarGroupID)
        }

        var target: Target
        var title: String
        var symbol: String
        var count: String
        var expansion = Expansion.none
        var selected = false
    }

    /// A reference row with what it shows besides its name.
    struct ReferenceRow: Equatable {
        var reference: GitReference
        var agent: AgentMarkState?
        var selected: Bool
        var comments = 0
        var isProduction = false
        var marks = Marks()
    }

    /// A folder of branches (the part before a slash), as in Fork; `nested` under a remote.
    struct Folder: Equatable {
        var id: SidebarGroupID
        var name: String
        var depth: Int
        var nested: Bool
        var count: Int
        var expanded: Bool
    }

    enum Row: Equatable {
        case header(String, String)
        case subheader(String, String)
        case repository(Repository, expanded: Bool)
        case checkout(Checkout, repository: URL, selected: Bool)
        case divider
        case nav(Nav)
        case reference(ReferenceRow)
        case stash(GitStash, selected: Bool)
        case empty(String)
        /// A configured remote (origin, upstream…) under Remotes; it expands to that remote's branches.
        /// `brand`: the host's mark (GitHub, GitLab, Bitbucket) in place of the generic network symbol.
        case remote(name: String, branches: Int, expanded: Bool, brand: BrandMarks.Brand? = nil)
        case folder(Folder)

        /// Rows of one kind have one height: a list whose kinds stay put reloads only the rows that changed.
        var kind: Int {
            switch self {
            case .header: 0
            case .repository: 1
            case .checkout: 2
            case .divider: 3
            case .nav: 4
            case .reference: 5
            case .stash: 6
            case .empty: 7
            case .remote: 8
            case .folder: 9
            case .subheader: 10
            }
        }

        var isSelected: Bool {
            switch self {
            case .nav(let nav): nav.selected
            case .reference(let row): row.selected
            case .stash(_, let selected): selected
            default: false
            }
        }

        static let headerHeight: CGFloat = 26
        static let subheaderHeight: CGFloat = 22
        static let agentCheckoutHeight: CGFloat = 38
        static let dividerHeight: CGFloat = 17

        @MainActor var height: CGFloat {
            switch self {
            case .header: Self.headerHeight
            case .subheader: Self.subheaderHeight
            case .checkout(let checkout, _, _):
                WindowAgents.crowd(checkout.sessions) == nil ? Theme.rowHeight : Self.agentCheckoutHeight
            case .divider: Self.dividerHeight
            default: Theme.rowHeight
            }
        }

        /// The group the row opens and closes, and whether it is open (nil: not a group, or one with nothing in it).
        var group: (id: SidebarGroupID, expanded: Bool)? {
            switch self {
            case .nav(let nav):
                guard case .group(let id) = nav.target, nav.expansion != .none else { return nil }
                return (id, nav.expansion == .expanded)
            case .remote(let name, _, let expanded, _): return (.remote(name), expanded)
            case .folder(let folder): return (folder.id, folder.expanded)
            default: return nil
            }
        }

        /// Groups (Branches, Tags…) only expand and collapse: a click does not select them, so no selection flashes
        /// on the way. The arrow keys do stop on them (`group`), so the keyboard can open and close them too.
        var isSelectable: Bool {
            switch self {
            case .header, .subheader, .divider, .empty, .remote, .folder: false
            case .nav(let nav): if case .page = nav.target { true } else { false }
            default: true
            }
        }
    }
}
