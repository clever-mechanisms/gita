import GitaCore

/// The lanes of one graph row past the lanes drawn (`GraphCell.maximumLanes`): their lines end at the edge and the
/// row shows how many there are.
struct GraphOverflow: Equatable {
    /// Lanes of this row past the edge: the commit's own and the lines through or out of it.
    let hidden: Int
    /// The commit's own lane is past the edge: its node is drawn at the edge.
    let nodeHidden: Bool
    /// The commit's lane and the row's last lane, counted from 1.
    let lane: Int
    let lanes: Int

    /// Nil when every lane of `row` is drawn.
    init?(row: GraphRow, limit: Int) {
        let last = Self.lastLane(of: row)
        guard last >= limit else { return nil }
        hidden = last - limit + 1
        nodeHidden = row.lane >= limit
        lane = row.lane + 1
        lanes = last + 1
    }

    /// `row` without the lines that lie wholly past the edge: lanes from `limit` on are not drawn, and a line between
    /// two of them never reaches a lane that is (a lane only moves right where the row below opens one).
    static func visible(_ row: GraphRow, limit: Int) -> GraphRow {
        let drawn = { (edge: GraphEdge) in min(edge.from, edge.to) < limit }
        return GraphRow(
            lane: row.lane, color: row.color, incoming: row.incoming.filter(drawn), outgoing: row.outgoing.filter(drawn)
        )
    }

    /// The rightmost lane any line of `row` (or its node) uses.
    static func lastLane(of row: GraphRow) -> Int {
        let widest = { (lane: Int, edge: GraphEdge) in max(lane, edge.from, edge.to) }
        return row.outgoing.reduce(row.incoming.reduce(row.lane, widest), widest)
    }
}
