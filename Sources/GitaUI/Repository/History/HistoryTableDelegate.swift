import AppKit
import GitaCore

/// What the history table asks of, and tells, the repository window.
@MainActor
protocol HistoryTableDelegate: AnyObject {
    /// Who merged a merge commit and how many commits it brought in.
    func historyFlair(for commit: GitCommit) -> MergeFlair?
    /// The Status column's chips for a commit (cached by the table until it measures them again).
    func historyChips(for commit: GitCommit) -> [HistoryChip]
    /// The commits that can have chips; only these are measured for the Status column's width.
    func historyChipCandidates() -> Set<String>
    /// The user chose a row.
    func historyDidSelect(_ commit: GitCommit)
    /// The user cleared the selection (Command-click on the selected row): no commit is reviewed.
    func historyDidDeselect()
    func historyMergeChip(_ event: HistoryMergeChipEvent)
    func historyShowReferences(of commitID: String, rect: NSRect, in view: NSView)
    func historyOpenChip(_ target: HistoryChip.Target, commitID: String)
    /// The list scrolled.
    func historyDidScroll()
}

/// The merge chip on a history row (`HistoryCommitCell`).
enum HistoryMergeChipEvent {
    case hover(id: String, rect: NSRect, view: NSView)
    case hoverEnded
    case click(id: String, rect: NSRect, view: NSView)
    /// The eye button: fold an expanded merge again.
    case hide(id: String)
}
