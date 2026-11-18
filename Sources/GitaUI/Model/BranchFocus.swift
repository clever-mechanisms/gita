import Foundation
import GitaCore

/// The history of one branch shown alone (sidebar › a branch): its own pages, graph and index.
struct BranchFocus {
    var reference: GitReference?
    var commits: [GitCommit] = []
    var graph: [GraphRow] = []
    var index = HistoryIndex.empty
    /// Replaced on every focus change so pages read for an earlier focus never land.
    private(set) var identity = UUID()
    var hasMore = false
    /// The page read in flight, or how the last one failed; a discarded focus takes its failure with it.
    var read = HistoryPageRead.idle
    /// The whole history's selection, restored when the focus ends.
    var allHistorySelection: GitCommit?

    var isActive: Bool { reference != nil }
    var isLoading: Bool { read.isReading }

    /// Ends the focus (the remembered selection stays; callers clear it when it no longer applies).
    mutating func discard() {
        read.cancel()
        identity = UUID()
        reference = nil
        commits = []
        graph = []
        index = .empty
        hasMore = false
    }
}
