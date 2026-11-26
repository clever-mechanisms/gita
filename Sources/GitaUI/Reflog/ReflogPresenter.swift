import AppKit
import GitaCore

/// Filter mode for the Reflog / Visual Undo Browser.
enum ReflogFilter: Equatable, Sendable {
    case all
    case orphaned
    case resets
    case rebases
    case commits

    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .orphaned: String(localized: "Orphaned")
        case .resets: String(localized: "Resets")
        case .rebases: String(localized: "Rebases")
        case .commits: String(localized: "Commits")
        }
    }

    static let ordered: [Self] = [.all, .orphaned, .resets, .rebases, .commits]

    func matches(_ entry: ReflogEntry) -> Bool {
        switch self {
        case .all: true
        case .orphaned: entry.isOrphaned
        case .resets: entry.actionKind == .reset
        case .rebases: entry.actionKind == .rebase
        case .commits: entry.actionKind == .commit || entry.actionKind == .amend
        }
    }
}

/// Lifecycle state for loading a selected reflog entry's changed files and per-file diff preview.
enum ReflogDiffState: Equatable, Sendable {
    case idle
    case loading(commitID: String)
    case loadingFile(commitID: String, files: [String], path: String)
    case loaded(commitID: String, files: [String], path: String?, diff: String)
    case failed(commitID: String, files: [String], path: String?, message: String)

    var files: [String] {
        switch self {
        case .idle, .loading: []
        case .loadingFile(_, let files, _), .loaded(_, let files, _, _), .failed(_, let files, _, _): files
        }
    }

    var selectedPath: String? {
        switch self {
        case .idle, .loading: nil
        case .loadingFile(_, _, let path): path
        case .loaded(_, _, let path, _), .failed(_, _, let path, _): path
        }
    }
}

/// Visual badge metadata for one `ReflogActionKind`.
@MainActor
struct ReflogActionBadge {
    let title: String
    let accentColor: NSColor

    static func badge(for kind: ReflogActionKind) -> Self {
        switch kind {
        case .commit:
            Self(title: String(localized: "Commit"), accentColor: Theme.success)
        case .amend:
            Self(title: String(localized: "Amend"), accentColor: Theme.needsInputText)
        case .checkout:
            Self(title: String(localized: "Checkout"), accentColor: Theme.working)
        case .reset:
            Self(title: String(localized: "Reset"), accentColor: Theme.failure)
        case .rebase:
            Self(title: String(localized: "Rebase"), accentColor: Theme.merged)
        case .merge:
            Self(title: String(localized: "Merge"), accentColor: Theme.running)
        case .cherryPick:
            Self(title: String(localized: "Cherry-pick"), accentColor: Theme.merged)
        case .pull:
            Self(title: String(localized: "Pull"), accentColor: Theme.running)
        case .branch:
            Self(title: String(localized: "Branch"), accentColor: Theme.working)
        case .stash:
            Self(title: String(localized: "Stash"), accentColor: Theme.secondaryText)
        case .other:
            Self(title: String(localized: "Action"), accentColor: Theme.secondaryText)
        }
    }
}

/// Coordinates reflog loading, filtering, per-file diff preview loading, and recovery actions without a window.
@MainActor
final class ReflogPresenter {
    typealias ReflogLoader = @Sendable (String, Int) async throws -> [ReflogEntry]
    typealias FilesLoader = @Sendable (String) async throws -> [String]
    typealias FileDiffLoader = @Sendable (String, String?) async throws -> String
    typealias BranchCreator = @Sendable (String, String) async throws -> Void

    private(set) var loadState: ReflogLoadState = .idle
    private(set) var diffState: ReflogDiffState = .idle
    private(set) var filter: ReflogFilter = .all
    private(set) var searchQuery = ""
    private(set) var selectedEntryID: String?
    private(set) var refName = "HEAD"

    var onChange: (() -> Void)?
    var onRepositoryMutated: (() -> Void)?

    private let loadReflog: ReflogLoader
    private let loadFiles: FilesLoader
    private let loadFileDiff: FileDiffLoader
    private let createBranchAction: BranchCreator
    private let listTask = LatestTask()
    private let diffTask = LatestTask()

    convenience init(service: GitService) {
        self.init(
            loadReflog: { ref, limit in try await service.reflog(ref: ref, limit: limit) },
            loadFiles: { commitID in try await service.reflogChangedFiles(commitID: commitID).map(\.path) },
            loadFileDiff: { commitID, path in try await service.reflogCommitDiff(commitID: commitID, path: path) },
            createBranch: { name, commitID in try await service.createBranchFromReflog(name: name, commitID: commitID) }
        )
    }

    init(
        loadReflog: @escaping ReflogLoader,
        loadFiles: @escaping FilesLoader,
        loadFileDiff: @escaping FileDiffLoader,
        createBranch: @escaping BranchCreator
    ) {
        self.loadReflog = loadReflog
        self.loadFiles = loadFiles
        self.loadFileDiff = loadFileDiff
        self.createBranchAction = createBranch
    }

    var visibleEntries: [ReflogEntry] {
        Self.filteredEntries(from: loadState.entries, filter: filter, query: searchQuery)
    }

    var orphanedCount: Int {
        loadState.entries.filter(\.isOrphaned).count
    }

    var selectedEntry: ReflogEntry? {
        guard let selectedEntryID else { return nil }
        return visibleEntries.first { $0.id == selectedEntryID }
    }

    var statusSummary: String {
        switch loadState {
        case .idle:
            return ""
        case .loading:
            return String(localized: "Loading reflog…")
        case .failed(let message):
            return message
        case .loaded(let all):
            let shown = visibleEntries.count
            let orphaned = orphanedCount
            if all.isEmpty {
                return String(localized: "No reflog entries")
            }
            if orphaned > 0 {
                return String(localized: "\(shown) of \(all.count) entries · \(orphaned) orphaned")
            }
            return String(localized: "\(shown) of \(all.count) entries")
        }
    }

    static func filteredEntries(
        from entries: [ReflogEntry], filter: ReflogFilter, query: String
    ) -> [ReflogEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            guard filter.matches(entry) else { return false }
            guard !trimmed.isEmpty else { return true }
            return entry.subject.localizedCaseInsensitiveContains(trimmed)
                || entry.actionSummary.localizedCaseInsensitiveContains(trimmed)
                || entry.selector.localizedCaseInsensitiveContains(trimmed)
                || entry.commitID.localizedCaseInsensitiveContains(trimmed)
                || entry.author.localizedCaseInsensitiveContains(trimmed)
        }
    }

    func suggestedRecoveryBranchName(for entry: ReflogEntry) -> String {
        "recover-\(entry.shortID)"
    }

    func reload(ref: String? = nil, limit: Int = 200) {
        if let ref { refName = ref }
        let targetRef = refName
        loadState = .loading
        diffState = .idle
        onChange?()
        listTask.run(
            { [loadReflog] in try await loadReflog(targetRef, limit) },
            then: { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let entries):
                    self.loadState = .loaded(entries)
                    self.ensureValidSelection()
                case .failure(let error):
                    self.loadState = .failed(error.localizedDescription)
                    self.selectedEntryID = nil
                }
                self.onChange?()
            }
        )
    }

    func setFilter(_ next: ReflogFilter) {
        guard filter != next else { return }
        filter = next
        ensureValidSelection()
        onChange?()
    }

    func setSearchQuery(_ query: String) {
        guard searchQuery != query else { return }
        searchQuery = query
        ensureValidSelection()
        onChange?()
    }

    func select(entryID: String?) {
        guard selectedEntryID != entryID else { return }
        selectedEntryID = entryID
        loadSelectedCommitFiles()
        onChange?()
    }

    func selectFile(_ path: String) {
        guard let commitID = selectedEntry?.commitID else { return }
        let files = diffState.files
        guard files.contains(path), diffState.selectedPath != path else { return }
        loadDiffForFile(commitID: commitID, files: files, path: path)
    }

    func createBranch(named name: String, at entry: ReflogEntry) async throws {
        try await createBranchAction(name, entry.commitID)
        onRepositoryMutated?()
        reload()
    }

    func cancelAll() {
        listTask.cancel()
        diffTask.cancel()
    }

    private func ensureValidSelection() {
        let shown = visibleEntries
        if let selectedEntryID, shown.contains(where: { $0.id == selectedEntryID }) {
            loadSelectedCommitFiles()
            return
        }
        selectedEntryID = shown.first?.id
        loadSelectedCommitFiles()
    }

    private func loadSelectedCommitFiles() {
        guard let entry = selectedEntry else {
            diffTask.cancel()
            diffState = .idle
            return
        }
        let commitID = entry.commitID
        if case .loaded(let loadedID, _, _, _) = diffState, loadedID == commitID { return }
        diffState = .loading(commitID: commitID)
        diffTask.run(
            { [loadFiles, loadFileDiff] () async throws -> ReflogDiffState in
                let files = try await loadFiles(commitID)
                guard let first = files.first else {
                    return .loaded(commitID: commitID, files: [], path: nil, diff: "")
                }
                do {
                    let text = try await loadFileDiff(commitID, first)
                    return .loaded(commitID: commitID, files: files, path: first, diff: text)
                } catch {
                    return .failed(
                        commitID: commitID, files: files, path: first, message: error.localizedDescription)
                }
            },
            then: { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let nextState):
                    self.diffState = nextState
                case .failure(let error):
                    self.diffState = .failed(
                        commitID: commitID, files: [], path: nil, message: error.localizedDescription)
                }
                self.onChange?()
            }
        )
    }

    private func loadDiffForFile(commitID: String, files: [String], path: String) {
        diffState = .loadingFile(commitID: commitID, files: files, path: path)
        onChange?()
        diffTask.run(
            { [loadFileDiff] in try await loadFileDiff(commitID, path) },
            then: { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let text):
                    self.diffState = .loaded(commitID: commitID, files: files, path: path, diff: text)
                case .failure(let error):
                    self.diffState = .failed(
                        commitID: commitID, files: files, path: path, message: error.localizedDescription)
                }
                self.onChange?()
            }
        )
    }
}
