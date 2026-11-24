import GitaCore

/// What the review pane reviews: one of them, so a commit and a stash, or a base without a commit, cannot both be set.
enum ReviewTarget: Equatable {
    /// The working tree's changes; also what an empty selection (nothing picked in the history) reads.
    case workingTree
    /// A commit, compared with `base` (nil: its first parent).
    case commit(GitCommit, base: String?)
    case stash(GitStash)
}

/// What the diff pane shows of the review: a file's diff, or (in a commit's tree review) an entry's contents.
enum ReviewItem: Equatable {
    case none
    case file(FileChange)
    case treeEntry(path: String)
}

/// What the review pane shows: a commit or stash (or the working tree), its files, and the selected file's diff.
struct SelectionState {
    var target = ReviewTarget.workingTree
    var item = ReviewItem.none
    var details: CommitDetails?
    var files: [FileChange] = [] { didSet { filesRevision &+= 1 } }
    /// Changes whenever `files` is assigned, so views rebuild their rows only for a new list.
    private(set) var filesRevision = 0
    var diff = ""
    /// Exact byte size when the selected tree blob is binary.
    var binaryBlobByteCount: Int64?
    /// The path whose diff is shown; a refresh of the same path keeps the reader's place.
    var diffPath: String?
    /// The commit's files tree is shown instead of its changes (kept across selections).
    var isTreeReview = false
    var isDiffLoading = false
    /// Bumped by every new selection so a slower earlier read never lands.
    private(set) var generation = 0
    var task: Task<Void, Never>?

    /// The reviewed commit. Set when a refresh finds the same commit with new decorations: its base stays. Without a
    /// commit no tree entry stays shown either: only a commit has a tree.
    var commit: GitCommit? {
        get {
            if case .commit(let commit, _) = target { commit } else { nil }
        }
        set {
            target = newValue.map { .commit($0, base: base) } ?? .workingTree
            if newValue == nil, treePath != nil { item = .none }
        }
    }

    var stash: GitStash? {
        if case .stash(let stash) = target { stash } else { nil }
    }

    /// The parent a merge is compared with (nil: its first parent, or no commit reviewed).
    var base: String? {
        if case .commit(_, let base) = target { base } else { nil }
    }

    var file: FileChange? {
        if case .file(let file) = item { file } else { nil }
    }

    var treePath: String? {
        if case .treeEntry(let path) = item { path } else { nil }
    }

    /// The diff pane holds a tree entry's contents, not a diff.
    var diffIsBlob: Bool { treePath != nil }

    /// Starts a new selection: everything shown is cleared (the files revision keeps counting).
    mutating func clear() {
        generation += 1
        target = .workingTree
        item = .none
        details = nil
        files = []
        diff = ""
        binaryBlobByteCount = nil
        diffPath = nil
        isDiffLoading = false
    }

    /// A new read for the current selection (a file, a tree entry) supersedes the earlier one.
    mutating func supersede() { generation += 1 }
}
