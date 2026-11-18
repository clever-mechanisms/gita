import Foundation

/// The read of a commit's top-level tree, and what the label over the outline says meanwhile.
enum CommitTreeRootLoad: Equatable {
    case noCommit
    case loading
    case loaded(isEmpty: Bool)
    case failed

    init(commit: String?) { self = commit == nil ? .noCommit : .loading }

    /// The label over the outline; nil once rows show.
    var placeholder: String? {
        switch self {
        case .noCommit: String(localized: "Select a commit")
        case .loading: String(localized: "Loading tree…")
        case .loaded(isEmpty: true): String(localized: "Empty tree")
        case .loaded(isEmpty: false): nil
        case .failed: String(localized: "Tree unavailable")
        }
    }
}

/// Show in File Tree's walk down to one path. It ends when the path is selected, when another commit is shown, or
/// when a folder it needs fails to load, so a stale walk never moves the selection later.
struct CommitTreeReveal: Equatable {
    private(set) var path: String?

    mutating func request(_ path: String) { self.path = path }
    /// The path was selected, cannot be found, or the commit changed.
    mutating func end() { path = nil }
    /// A folder failed to load (`""` is the root): the walk stops when it needed that folder.
    mutating func failed(folder: String) {
        guard let path, folder.isEmpty || CommitTreeOrder.pathPrefixes(path).contains(folder) else { return }
        self.path = nil
    }
}
