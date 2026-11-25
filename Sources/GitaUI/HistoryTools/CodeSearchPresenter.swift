import Foundation
import GitaCore

/// Lifecycle state for on-demand per-file diff loading in Code Search.
public enum CodeSearchDiffState: Sendable, Equatable {
    case idle
    case loading(commitID: String, path: String?)
    case loaded(commitID: String, path: String?, diff: String)
    case failed(commitID: String, path: String?, message: String)

    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    public var selectedPath: String? {
        switch self {
        case .idle: nil
        case .loading(_, let path), .loaded(_, let path, _), .failed(_, let path, _): path
        }
    }

    public var diffText: String {
        if case .loaded(_, _, let diff) = self { return diff }
        return ""
    }

    public var errorMessage: String? {
        if case .failed(_, _, let message) = self { return message }
        return nil
    }
}

/// Coordinates Git Pickaxe (`-S` literal / `-G` regex) code search and on-demand per-file diff loading.
@MainActor
public final class CodeSearchPresenter {
    public typealias Searcher = @Sendable (PickaxeQuery) async throws -> [PickaxeMatch]
    public typealias FileDiffLoader = @Sendable (String, String?) async throws -> String

    public private(set) var state: CodeSearchState = .idle
    public private(set) var diffState: CodeSearchDiffState = .idle
    public private(set) var pattern = ""
    public private(set) var mode: PickaxeMode = .literal
    public private(set) var pathFilter = ""
    public private(set) var ignoreCase = false
    public private(set) var selectedCommitID: String?
    public var onChange: (() -> Void)?

    private let searcher: Searcher
    private let loadFileDiff: FileDiffLoader
    private let searchTask = LatestTask()
    private let diffTask = LatestTask()

    public init(service: GitService) {
        self.searcher = { query in try await service.searchCode(query) }
        self.loadFileDiff = { commitID, path in try await service.pickaxeFileDiff(commitID: commitID, path: path) }
    }

    public init(searcher: @escaping Searcher, loadFileDiff: @escaping FileDiffLoader = { _, _ in "" }) {
        self.searcher = searcher
        self.loadFileDiff = loadFileDiff
    }

    public var matches: [PickaxeMatch] { state.matches }

    public var selectedMatch: PickaxeMatch? {
        guard let selectedCommitID else { return nil }
        return matches.first { $0.commit.id == selectedCommitID }
    }

    /// Spaces are significant in `-S` / `-G`, so any non-empty pattern is searchable.
    public var canSearch: Bool { !pattern.isEmpty }

    public var statusSummary: String {
        switch state {
        case .idle:
            return String(localized: "Search commits that added, removed, or changed code matching a pattern.")
        case .searching(let query):
            let flag = query.mode == .literal ? "-S" : "-G"
            return String(localized: "Searching history (\(flag)) for “\(query.pattern)”…")
        case .failed(_, let message):
            return message
        case .results(let query, let items):
            let flag = query.mode == .literal ? "-S" : "-G"
            if items.isEmpty {
                return String(localized: "No commits matched “\(query.pattern)” (\(flag))")
            }
            if items.count == 1 {
                return String(localized: "1 matching commit (\(flag))")
            }
            return String(localized: "\(items.count) matching commits (\(flag))")
        }
    }

    public func setPattern(_ next: String) {
        guard pattern != next else { return }
        pattern = next
        onChange?()
    }

    public func setMode(_ next: PickaxeMode) {
        guard mode != next else { return }
        mode = next
        onChange?()
    }

    public func setPathFilter(_ next: String) {
        guard pathFilter != next else { return }
        pathFilter = next
        onChange?()
    }

    public func setIgnoreCase(_ next: Bool) {
        guard ignoreCase != next else { return }
        ignoreCase = next
        onChange?()
    }

    public func search(limit: Int = 100) {
        guard !pattern.isEmpty else {
            cancel()
            state = .idle
            diffState = .idle
            selectedCommitID = nil
            onChange?()
            return
        }
        let query = PickaxeQuery(
            pattern: pattern,
            mode: mode,
            pathFilter: pathFilter,
            ignoreCase: ignoreCase,
            limit: limit
        )
        state = .searching(query)
        diffState = .idle
        selectedCommitID = nil
        diffTask.cancel()
        onChange?()
        searchTask.run(
            { [searcher] in try await searcher(query) },
            then: { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let items):
                    self.state = .results(query, items)
                    self.selectedCommitID = items.first?.commit.id
                    self.loadSelectedDiff(path: items.first?.matchedFiles.first)
                case .failure(let error):
                    self.state = .failed(query, error.localizedDescription)
                    self.selectedCommitID = nil
                }
                self.onChange?()
            }
        )
    }

    public func select(commitID: String?) {
        guard selectedCommitID != commitID else { return }
        selectedCommitID = commitID
        loadSelectedDiff(path: selectedMatch?.matchedFiles.first)
        onChange?()
    }

    public func selectFile(_ path: String) {
        guard let match = selectedMatch, match.matchedFiles.contains(path), diffState.selectedPath != path else {
            return
        }
        loadSelectedDiff(path: path)
        onChange?()
    }

    public func cancel() {
        searchTask.cancel()
        diffTask.cancel()
    }

    private func loadSelectedDiff(path: String?) {
        guard let match = selectedMatch else {
            diffTask.cancel()
            diffState = .idle
            return
        }
        let commitID = match.commit.id
        diffState = .loading(commitID: commitID, path: path)
        diffTask.run(
            { [loadFileDiff] in try await loadFileDiff(commitID, path) },
            then: { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let text):
                    self.diffState = .loaded(commitID: commitID, path: path, diff: text)
                case .failure(let error):
                    self.diffState = .failed(commitID: commitID, path: path, message: error.localizedDescription)
                }
                self.onChange?()
            }
        )
    }
}
