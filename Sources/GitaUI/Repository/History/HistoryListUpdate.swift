import GitaCore

/// One history list: the rows, their graph, and what they were drawn for.
struct HistoryListState {
    struct Signature: Equatable {
        var mode: HistoryMode
        var head: String?
        var remoteNames: Set<String>
        /// `AppModel.squashRevision`: squash links change the graph, not the commits.
        var squashRevision: Int

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.squashRevision == rhs.squashRevision && lhs.head == rhs.head && lhs.mode == rhs.mode
                && lhs.remoteNames == rhs.remoteNames
        }
    }

    var signature: Signature
    var commits: [GitCommit]
    var graphs: [GraphRow]
}

/// How the shown list follows a new one: keep it (a working-tree refresh), append a further page below it, or reload.
enum HistoryListUpdate: Equatable {
    case unchanged
    case append
    case reload

    /// `graphCanChange`: rows already shown can be laid out again by a further page (squash links or a collapsed
    /// history); their graph is then compared before appending.
    static func plan(from shown: HistoryListState?, to next: HistoryListState, graphCanChange: Bool) -> Self {
        guard let shown, shown.signature == next.signature else { return .reload }
        if next.commits.count == shown.commits.count, next.commits.elementsEqual(shown.commits) { return .unchanged }
        // Search results are not an ancestry walk: a further page reloads them.
        guard !next.signature.mode.isSearch, !shown.commits.isEmpty, next.commits.count > shown.commits.count,
            next.commits.prefix(shown.commits.count).elementsEqual(shown.commits)
        else { return .reload }
        if graphCanChange, !next.graphs.prefix(shown.graphs.count).elementsEqual(shown.graphs) { return .reload }
        return .append
    }
}

extension HistoryListState {
    /// The highest lane any row or edge in `rows` uses, starting from `lane`.
    static func lastLane(of rows: some Sequence<GraphRow>, from lane: Int = 0) -> Int {
        rows.reduce(lane) { lane, row in
            let incoming = row.incoming.reduce(lane) { max($0, $1.from, $1.to) }
            return row.outgoing.reduce(max(incoming, row.lane)) { max($0, $1.from, $1.to) }
        }
    }
}
