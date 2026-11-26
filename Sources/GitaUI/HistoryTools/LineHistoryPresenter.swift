import Foundation
import GitaCore

/// Coordinates `git log -L` line history loading, selection, and presentation without requiring a window.
@MainActor
final class LineHistoryPresenter {
    typealias Loader = @Sendable (LineRangeSpec, Int) async throws -> [LineHistoryEntry]

    private(set) var range: LineRangeSpec
    private(set) var state: LineHistoryLoadState = .idle
    private(set) var selectedCommitID: String?
    var onChange: (() -> Void)?

    private let loader: Loader
    private let task = LatestTask()

    convenience init(service: GitService, range: LineRangeSpec) {
        self.init(range: range) { spec, limit in try await service.lineHistory(range: spec, limit: limit) }
    }

    init(range: LineRangeSpec, loader: @escaping Loader) {
        self.range = range
        self.loader = loader
    }

    var entries: [LineHistoryEntry] { state.entries }

    var selectedEntry: LineHistoryEntry? {
        guard let selectedCommitID else { return nil }
        return entries.first { $0.commit.id == selectedCommitID }
    }

    var headerTitle: String {
        String(localized: "Line History · \(range.path) (\(range.rangeLabel))")
    }

    var summaryText: String {
        switch state {
        case .idle:
            return ""
        case .loading:
            return String(localized: "Tracing line evolution…")
        case .failed(let message):
            return message
        case .loaded(let items):
            if items.isEmpty { return String(localized: "No commits touched these lines") }
            if items.count == 1 { return String(localized: "1 commit touched these lines") }
            return String(localized: "\(items.count) commits touched these lines")
        }
    }

    func reload(range newRange: LineRangeSpec? = nil, limit: Int = 100) {
        if let newRange { range = newRange }
        let spec = range
        state = .loading
        onChange?()
        task.run(
            { [loader] in try await loader(spec, limit) },
            then: { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let items):
                    self.state = .loaded(items)
                    if let current = self.selectedCommitID, items.contains(where: { $0.commit.id == current }) {
                        self.selectedCommitID = current
                    } else {
                        self.selectedCommitID = items.first?.commit.id
                    }
                case .failure(let error):
                    self.state = .failed(error.localizedDescription)
                    self.selectedCommitID = nil
                }
                self.onChange?()
            }
        )
    }

    func select(commitID: String?) {
        guard selectedCommitID != commitID else { return }
        selectedCommitID = commitID
        onChange?()
    }

    func cancel() {
        task.cancel()
    }
}
