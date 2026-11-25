import Foundation
import GitaCore

/// Coordinates `git log -L` line history loading, selection, and presentation without requiring a window.
@MainActor
public final class LineHistoryPresenter {
    public typealias Loader = @Sendable (LineRangeSpec, Int) async throws -> [LineHistoryEntry]

    public private(set) var range: LineRangeSpec
    public private(set) var state: LineHistoryLoadState = .idle
    public private(set) var selectedCommitID: String?
    public var onChange: (() -> Void)?

    private let loader: Loader
    private let task = LatestTask()

    public init(service: GitService, range: LineRangeSpec) {
        self.range = range
        self.loader = { spec, limit in try await service.lineHistory(range: spec, limit: limit) }
    }

    public init(range: LineRangeSpec, loader: @escaping Loader) {
        self.range = range
        self.loader = loader
    }

    public var entries: [LineHistoryEntry] { state.entries }

    public var selectedEntry: LineHistoryEntry? {
        guard let selectedCommitID else { return nil }
        return entries.first { $0.commit.id == selectedCommitID }
    }

    public var headerTitle: String {
        String(localized: "Line History · \(range.path) (\(range.rangeLabel))")
    }

    public var summaryText: String {
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

    public func reload(range newRange: LineRangeSpec? = nil, limit: Int = 100) {
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

    public func select(commitID: String?) {
        guard selectedCommitID != commitID else { return }
        selectedCommitID = commitID
        onChange?()
    }

    public func cancel() {
        task.cancel()
    }
}
