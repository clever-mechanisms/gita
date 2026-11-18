import Foundation
import GitaCore

/// Which conflicted files Resolve Simple can merge on its own, read again whenever the set of conflicts changes, so
/// the operation bar offers it only when it would do something.
@MainActor
final class SimpleConflictScan {
    enum State: Equatable {
        case idle
        case scanning(conflicts: [String])
        case scanned(conflicts: [String], simple: [String])
    }

    private(set) var state = State.idle
    private let reads = LatestTask()
    /// The scan finished or was dropped: the bar shows the new count.
    var onChange: (() -> Void)?

    var simplePaths: [String] { if case .scanned(_, let simple) = state { simple } else { [] } }

    /// Scans `conflicts` unless they are the ones scanned (or being scanned) already.
    func update(conflicts: [String], service: GitService?) {
        guard let service, !conflicts.isEmpty else {
            guard state != .idle else { return }
            reads.cancel()
            state = .idle
            onChange?()
            return
        }
        switch state {
        case .scanning(let scanned), .scanned(let scanned, _): if scanned == conflicts { return }
        case .idle: break
        }
        state = .scanning(conflicts: conflicts)
        reads.run {
            var simple: [String] = []
            for path in conflicts {
                guard let document = try? await service.conflict(path: path),
                    MergeEditorState.simpleResult(document) != nil
                else { continue }
                simple.append(path)
            }
            return simple
        } then: { [weak self] result in
            guard let self else { return }
            self.state = .scanned(conflicts: conflicts, simple: (try? result.get()) ?? [])
            self.onChange?()
        }
    }

    func cancel() { reads.cancel() }
}
