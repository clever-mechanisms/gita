import AppKit

/// The history table's columns, looked up by identifier (never by position).
enum HistoryColumn: String, CaseIterable {
    case subject, author, date, sha, signals

    var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }

    var title: String {
        switch self {
        case .subject: String(localized: "History")
        case .author: String(localized: "Author")
        case .date: String(localized: "Date")
        case .sha: String(localized: "SHA")
        case .signals: String(localized: "Status")
        }
    }

    /// The width at 100 % zoom.
    var baseWidth: CGFloat {
        switch self {
        case .subject: 600
        case .author: 150
        case .date: 120
        case .sha: 76
        case .signals: 210
        }
    }

    /// Author, date and SHA scale with the history zoom; the subject absorbs the rest and Status fits its chips.
    var scalesWithZoom: Bool { self == .author || self == .date || self == .sha }

    var minimumWidth: CGFloat { self == .subject ? 260 : 45 }

    init?(_ identifier: NSUserInterfaceItemIdentifier?) {
        guard let identifier else { return nil }
        self.init(rawValue: identifier.rawValue)
    }
}

extension NSTableView {
    func column(_ column: HistoryColumn) -> NSTableColumn? { tableColumn(withIdentifier: column.identifier) }

    /// The column's current index, for row/column reloads.
    func columnIndexes(_ column: HistoryColumn) -> IndexSet {
        let index = self.column(withIdentifier: column.identifier)
        return index < 0 ? IndexSet() : IndexSet(integer: index)
    }
}
