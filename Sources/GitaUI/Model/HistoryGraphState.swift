import Foundation
import GitaCore

/// The search for squash merges (`AppModel.updateSquashLinks`), by the references it is for (`squashKey`). A failed
/// search forgets its key, so the next update searches again.
enum SquashSearch {
    case none
    case searching(key: String, Task<Void, Never>)
    case found(key: String)

    var key: String? {
        switch self {
        case .none: nil
        case .searching(let key, _), .found(let key): key
        }
    }

    mutating func cancel() {
        if case .searching(_, let task) = self { task.cancel() }
        self = .none
    }
}

/// The history laid out again in flight (`AppModel.relayoutHistory`). Only the latest one lands: one started while
/// another runs replaces it and takes over its callbacks, so an older layout never overwrites a newer one.
enum HistoryRelayout {
    case idle
    case running(UUID, Task<Void, Never>, then: [@MainActor () -> Void])
}

/// The laid-out history and what shapes it: folded merges, squash links and an author tab's links.
struct HistoryGraphState {
    /// Built off the main thread, set with the snapshot it describes.
    var layout = HistoryLayout.empty
    /// Merges opened in a collapsed history (Settings › Git › Collapse merged commits), by commit ID.
    var expandedMerges: Set<String> = []
    /// Squash commit → tip of the branch it squashed (`SquashMerges`), for the current references.
    var squashLinks: [String: String] = [:]
    /// Bumped when the graph is laid out again for new `squashLinks`, for the views and caches built on it.
    var squashRevision = 0
    var squashSearch = SquashSearch.none
    private(set) var relayout = HistoryRelayout.idle
    /// An author tab's graph links (`AuthorHistory.graphParents`) for the loaded commits.
    var lensLinks: [String: [String]] = [:]

    /// A newly opened repository: nothing laid out (the squash revision keeps counting).
    mutating func reset() {
        cancelSquashSearch()
        cancelRelayout()
        squashLinks = [:]
        squashRevision += 1
        layout = .empty
        expandedMerges = []
    }

    mutating func cancelSquashSearch() { squashSearch.cancel() }

    /// A relayout starts: the one in flight stops, and its callbacks wait for this one.
    mutating func startRelayout(_ id: UUID, _ task: Task<Void, Never>, then: (@MainActor () -> Void)?) {
        var waiting: [@MainActor () -> Void] = []
        if case .running(_, let older, let callbacks) = relayout {
            older.cancel()
            waiting = callbacks
        }
        if let then { waiting.append(then) }
        relayout = .running(id, task, then: waiting)
    }

    /// The relayout `id` ended: idle again, and handed back with the callbacks to run once its layout is in place;
    /// `idle` when another replaced it or it was cancelled (its layout never lands).
    mutating func endRelayout(_ id: UUID) -> HistoryRelayout {
        guard case .running(id, _, _) = relayout else { return .idle }
        defer { relayout = .idle }
        return relayout
    }

    /// The model stopped or another repository opened: no layout lands, and its callbacks never run.
    mutating func cancelRelayout() {
        if case .running(_, let task, _) = relayout { task.cancel() }
        relayout = .idle
    }

    /// The key squash links are found again for: HEAD and every reference tip.
    static func squashKey(_ snapshot: RepositorySnapshot) -> String {
        (snapshot.head ?? "") + "|" + snapshot.references.map { $0.fullName + " " + $0.commit }.joined(separator: "\n")
    }
}
