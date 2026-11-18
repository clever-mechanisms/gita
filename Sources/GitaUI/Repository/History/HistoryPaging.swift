import Foundation

/// Older history pages are read automatically once the list is scrolled near its bottom.
enum HistoryPaging {
    /// Automatic loading starts once this many commits are loaded (shorter lists are one page).
    static let automaticMinimum = 300
    /// Rows from the bottom at which the next page is read.
    static let prefetchRows: CGFloat = 40

    /// The visible bottom is within `prefetchRows` rows of the end of the list.
    static func isNearBottom(visibleMaxY: CGFloat, listHeight: CGFloat, rowHeight: CGFloat) -> Bool {
        visibleMaxY >= listHeight - rowHeight * prefetchRows
    }
}
