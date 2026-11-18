import AppKit
import GitaCore

/// Makes and configures one history cell per column.
@MainActor
struct HistoryCellFactory {
    /// Rows by other authors than the highlighted one fade to this.
    static let fadedAlpha: CGFloat = 0.3
    private static let shortSHA = 7
    private static let shaFontSize: CGFloat = 11
    private static let dateFontSize: CGFloat = 12

    var table: NSTableView
    var scale: CGFloat
    var head: String?
    var remoteNames: Set<String>
    var highlightedAuthor: CommitAuthor?
    var showsMergeLabel = true
    weak var delegate: (any HistoryTableDelegate)?
    /// The Status column's chips for a commit.
    var chips: (GitCommit) -> [HistoryChip]

    func cell(_ column: HistoryColumn, row: Int, commit: GitCommit, graphs: [GraphRow]) -> NSView {
        // Highlighting an author: everyone else's rows fade (the graph's lines stay, only their nodes fade).
        let faded = highlightedAuthor.map { !$0.wrote(commit) } ?? false
        let alpha: CGFloat = faded ? Self.fadedAlpha : 1
        switch column {
        case .subject: return subject(commit, row: row, graphs: graphs, alpha: alpha)
        case .signals: return signals(commit, alpha: alpha)
        case .author:
            let cell = reuse(column) { HistoryAuthorCell() }
            cell.email = commit.email
            cell.scale = scale
            cell.name = commit.author
            cell.alphaValue = alpha
            return cell
        case .sha, .date:
            let cell = reuse(column) { HistoryTextCell() }
            if column == .sha {
                cell.font = TextLines.monospaced(Self.shaFontSize * scale)
                cell.text = String(commit.id.prefix(Self.shortSHA))
                cell.toolTipDate = nil
            } else {
                cell.font = TextLines.system(Self.dateFontSize * scale)
                cell.text = DeckFormat.relative(commit.date)
                cell.toolTipDate = commit.date
            }
            cell.alphaValue = alpha
            return cell
        }
    }

    private func reuse<Cell: NSView>(_ column: HistoryColumn, make: () -> Cell) -> Cell {
        let cell = table.makeView(withIdentifier: column.identifier, owner: nil) as? Cell ?? make()
        cell.identifier = column.identifier
        return cell
    }

    private func subject(_ commit: GitCommit, row: Int, graphs: [GraphRow], alpha: CGFloat) -> HistoryCommitCell {
        let cell = reuse(.subject) { HistoryCommitCell() }
        cell.configure(
            HistoryCommitCell.Content(
                commit: commit, row: graphs.indices.contains(row) ? graphs[row] : nil,
                previous: graphs.indices.contains(row - 1) ? graphs[row - 1] : nil,
                next: graphs.indices.contains(row + 1) ? graphs[row + 1] : nil, scale: scale, isHead: commit.id == head,
                remoteNames: remoteNames, merge: delegate?.historyFlair(for: commit),
                showsMergeLabel: showsMergeLabel))
        cell.message.alphaValue = alpha
        cell.graph.nodeAlpha = alpha
        if cell.onMergeHover == nil { wire(cell) }
        return cell
    }

    private func wire(_ cell: HistoryCommitCell) {
        cell.onMergeHover = { [weak delegate] id, rect, view in
            delegate?.historyMergeChip(.hover(id: id, rect: rect, view: view))
        }
        cell.onMergeHoverEnd = { [weak delegate] in delegate?.historyMergeChip(.hoverEnded) }
        cell.onMergeClick = { [weak delegate] id, rect, view in
            delegate?.historyMergeChip(.click(id: id, rect: rect, view: view))
        }
        cell.onMergeHide = { [weak delegate] id in delegate?.historyMergeChip(.hide(id: id)) }
        cell.onReferencesClick = { [weak delegate] id, rect, view in
            delegate?.historyShowReferences(of: id, rect: rect, in: view)
        }
    }

    private func signals(_ commit: GitCommit, alpha: CGFloat) -> HistorySignalsCell {
        let cell = reuse(.signals) { HistorySignalsCell() }
        if cell.onOpen == nil {
            cell.onOpen = { [weak delegate] target, commitID in delegate?.historyOpenChip(target, commitID: commitID) }
        }
        cell.commitID = commit.id
        cell.update(chips: chips(commit), scale: scale)
        cell.alphaValue = alpha
        return cell
    }
}
