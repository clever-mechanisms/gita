import Foundation
import GitaCore

/// Single lifecycle enum for selection in the history table (`allowsMultipleSelection = true`).
enum HistorySelection: Equatable, Sendable {
    case none
    case commit(String)
    /// `(base, head)` in comparison order (`git diff base head`).
    case pair(String, String)
    case many([String])

    init(selectedRows: IndexSet, commits: [GitCommit]) {
        let valid = selectedRows.filter { commits.indices.contains($0) }
        switch valid.count {
        case 0:
            self = .none
        case 1:
            self = .commit(commits[valid[0]].id)
        case 2:
            // History lists newest first, so the larger row index is the older commit (base).
            self = .pair(commits[valid[1]].id, commits[valid[0]].id)
        default:
            self = .many(valid.map { commits[$0].id })
        }
    }

    var selectedIDs: [String] {
        switch self {
        case .none: []
        case .commit(let id): [id]
        case .pair(let base, let head): [head, base]
        case .many(let ids): ids
        }
    }

    func swapped() -> Self {
        guard case .pair(let base, let head) = self else { return self }
        return .pair(head, base)
    }
}
