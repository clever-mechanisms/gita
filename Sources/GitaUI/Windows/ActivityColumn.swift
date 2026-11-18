import AppKit

/// The Activity table's columns, in order.
enum ActivityColumn: String, CaseIterable {
    case time, source, event, result

    var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }
    /// The identifier of the column's reusable cells.
    var cellIdentifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier("activity." + rawValue) }

    var title: String {
        switch self {
        case .time: String(localized: "Time")
        case .source: String(localized: "Source")
        case .event: String(localized: "Event")
        case .result: String(localized: "Result")
        }
    }
    var width: CGFloat {
        switch self {
        case .time: 96
        case .source: 84
        case .event: 380
        case .result: 104
        }
    }
    var minimumWidth: CGFloat {
        switch self {
        case .time: 72
        case .source: 64
        case .event: 160
        case .result: 90
        }
    }

    @MainActor func makeTableColumn() -> NSTableColumn {
        let column = NSTableColumn(identifier: identifier)
        column.title = title
        column.width = width
        column.minWidth = minimumWidth
        // The event column takes the window's extra width.
        column.resizingMask = self == .event ? [.autoresizingMask, .userResizingMask] : .userResizingMask
        return column
    }
}
