import Foundation
import GitaCore

@MainActor
final class SmartDiffPresenter {
    private(set) var state = SmartDiffState.idle { didSet { onChange?(state) } }
    private(set) var options: SmartDiffOptions
    var onChange: ((SmartDiffState) -> Void)?
    private var expanded: Set<Int> = []
    private var source: SmartDiffSource?
    private var task: Task<Void, Never>?
    private var retryAction: (() -> Void)?

    init(options: SmartDiffOptions = SmartDiffOptions()) { self.options = options }

    @discardableResult
    func load(
        diffText: String, oldText: String? = nil, newText: String? = nil, filePath: String
    ) -> Task<Void, Never> {
        load(diffText: diffText, oldText: oldText, newText: newText, filePath: filePath, relatedDocuments: [:])
    }

    /// Supply the other files of the same change to enable cross-file move links.
    @discardableResult
    func load(
        diffText: String, oldText: String? = nil, newText: String? = nil, filePath: String,
        relatedDocuments: [String: DiffDocument]
    ) -> Task<Void, Never> {
        task?.cancel()
        expanded.removeAll()
        source = nil
        retryAction = nil
        state = .loading
        let options = options
        let work = Task.detached(priority: .userInitiated) { () -> (SmartDiffSource, SmartDiffSnapshot)? in
            guard !Task.isCancelled else { return nil }
            let structured: StructuredDiffResult
            if let oldText, let newText {
                structured = StructuredDiffFormatter.diff(oldText: oldText, newText: newText, path: filePath)
            } else {
                structured = .unsupported
            }
            guard !Task.isCancelled else { return nil }
            let source = SmartDiffSource(
                filePath: filePath, document: UnifiedDiff.parse(diffText),
                related: relatedDocuments, structured: structured)
            guard !Task.isCancelled else { return nil }
            return (source, source.snapshot(options: options, expanded: []))
        }
        let delivery = Task { [weak self] in
            let result = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
            guard !Task.isCancelled, let self, let (source, snapshot) = result else { return }
            self.source = source
            if self.options == options { self.publish(snapshot) } else { self.rebuild() }
        }
        task = delivery
        return delivery
    }

    func fail(_ message: String, retry: @escaping () -> Void) {
        task?.cancel()
        source = nil
        retryAction = retry
        state = .failed(message)
    }

    func retry() { retryAction?() }
    func toggleNoiseFilter() {
        options.hideNoise.toggle()
        expanded.removeAll()
        rebuild()
    }
    func toggleMoveDetection() {
        options.detectMoves.toggle()
        rebuild()
    }
    func toggleStructuredMode() {
        options.preferStructured.toggle()
        rebuild()
    }
    func toggleNoiseRun(hunkIndices: [Int]) {
        let indices = Set(hunkIndices)
        if indices.isSubset(of: expanded) { expanded.subtract(indices) } else { expanded.formUnion(indices) }
        rebuild()
    }

    func toggleAllNoise() {
        guard case .loaded(let snapshot) = state else { return }
        if snapshot.filtered.hiddenNoiseHunkCount > 0 {
            expanded.formUnion(snapshot.filtered.hiddenNoiseHunkIndices)
        } else {
            expanded.removeAll()
        }
        rebuild()
    }

    func jumpTarget(forMoveID id: String, fromLineIndex index: Int) -> (filePath: String, lineIndex: Int)? {
        guard case .loaded(let snapshot) = state,
            let match = snapshot.moves.matches.first(where: { $0.id == id })
        else { return nil }
        let endpoints = [match.source, match.destination]
        guard let from = endpoints.first(where: { $0.filePath == snapshot.filePath && $0.lineIndices.contains(index) })
        else { return nil }
        let to = from == match.source ? match.destination : match.source
        return (to.filePath, to.lineIndices.lowerBound + (index - from.lineIndices.lowerBound))
    }

    private func rebuild() {
        if let source { publish(source.snapshot(options: options, expanded: expanded)) }
    }

    private func publish(_ snapshot: SmartDiffSnapshot) {
        state = snapshot.displayRows.isEmpty && snapshot.document.lines.isEmpty ? .empty : .loaded(snapshot)
    }

    deinit { task?.cancel() }
}
