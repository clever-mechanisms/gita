import CoreGraphics

/// What the content area shows for a page section, and its remembered divider positions.
struct SectionPanes: Equatable {
    /// Per-section divider memory: Local Changes collapses history to 0 by default and uses a 260 pt left column;
    /// History remembers its own file-pane width and detail height.
    struct DividerMemory: Equatable {
        var changesHistoryHeight: CGFloat = 0
        private var filePaneWidths: [Section: CGFloat] = [:]

        func filePaneWidth(for section: Section) -> CGFloat {
            let spec = SectionPanes(section)
            let stored = filePaneWidths[section] ?? spec.defaultFilePaneWidth
            return max(spec.filePaneMinimum, stored)
        }

        mutating func setFilePaneWidth(_ width: CGFloat, for section: Section) {
            let minimum = SectionPanes(section).filePaneMinimum
            filePaneWidths[section] = max(minimum, width)
        }
    }

    var showsHistoryPane: Bool
    var showsCommitFooter: Bool
    var collapsesHistoryByDefault: Bool
    var filePaneMinimum: CGFloat
    var defaultFilePaneWidth: CGFloat

    init(_ section: Section) {
        showsHistoryPane = section == .history || section == .changes
        showsCommitFooter = section == .changes
        collapsesHistoryByDefault = section == .changes
        filePaneMinimum =
            section == .changes ? RepositoryLayout.changesFilePaneMinimum : RepositoryLayout.filePaneMinimum
        defaultFilePaneWidth =
            section == .changes ? RepositoryLayout.changesFilePaneMinimum : RepositoryLayout.filePaneWidth
    }
}
