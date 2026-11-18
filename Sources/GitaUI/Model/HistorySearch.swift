import GitaCore

/// A page read of a search or a branch focus: running with its task, or failed (the list offers Retry until the
/// next read of that list). Cancelling returns it to `idle`, so an ended list never stays "loading".
enum HistoryPageRead {
    case idle
    case reading(Task<Void, Never>)
    case failed

    var isReading: Bool {
        if case .reading = self { true } else { false }
    }

    var hasFailed: Bool {
        if case .failed = self { true } else { false }
    }

    mutating func cancel() {
        if case .reading(let task) = self { task.cancel() }
        self = .idle
    }
}

/// A history search: the query, the pages of results read so far and the page read in flight.
struct HistorySearch {
    var query = ""
    var field: HistorySearchField = .message
    var results: [GitCommit] = []
    var hasMore = false
    var read = HistoryPageRead.idle
    /// Bumped by every new query so a slower earlier page never lands.
    private(set) var generation = 0

    var isActive: Bool { !query.isEmpty }
    var isSearching: Bool { read.isReading }

    /// Ends the search (its field stays for the next one).
    mutating func clear() { begin("", field: field) }

    /// A new query: no results and no page read yet.
    mutating func begin(_ query: String, field: HistorySearchField) {
        invalidate()
        self.query = query
        self.field = field
        results = []
        hasMore = false
    }

    /// No page read for the current query lands (the model stopped): the one in flight ends.
    mutating func invalidate() {
        generation += 1
        read.cancel()
    }
}
