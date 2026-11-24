import Foundation
import GitaCore

/// What the history list shows: every branch, one focused reference, inline author filter, or search results.
enum HistoryMode: Hashable {
    case all
    /// A reference's own history; the identity changes whenever its list is read again.
    case focused(UUID)
    /// An inline `⏷` author filter; the identity changes whenever its list is read again.
    case authorFilter(UUID)
    case search(HistorySearchField, String)

    init(
        searchQuery: String, field: HistorySearchField, focusedIdentity: UUID?,
        authorFilterIdentity: UUID? = nil
    ) {
        if !searchQuery.isEmpty {
            self = .search(field, searchQuery)
        } else if let authorFilterIdentity {
            self = .authorFilter(authorFilterIdentity)
        } else if let focusedIdentity {
            self = .focused(focusedIdentity)
        } else {
            self = .all
        }
    }

    var isSearch: Bool {
        if case .search = self { return true }
        return false
    }
}

/// Where the list scrolls when the mode changes: back to the place All Commits was left at (scaled to the current row
/// height), or to the top of a focused or searched list.
struct HistoryScrollMemory {
    private(set) var mode = HistoryMode.all
    private var allOrigin = CGPoint.zero
    private var allRowHeight: CGFloat = 24

    /// The origin to show for `next`, given the list's current origin and row height.
    mutating func origin(for next: HistoryMode, current: CGPoint, rowHeight: CGFloat) -> CGPoint {
        guard next != mode else { return current }
        if mode == .all {
            allOrigin = current
            allRowHeight = rowHeight
        }
        mode = next
        guard next == .all else { return CGPoint(x: 0, y: min(0, current.y)) }
        var origin = allOrigin
        if origin.y >= 0 { origin.y *= rowHeight / max(1, allRowHeight) }
        return origin
    }
}
