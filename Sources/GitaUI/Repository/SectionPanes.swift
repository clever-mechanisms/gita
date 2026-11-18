/// What the content area shows for a page section.
struct SectionPanes: Equatable {
    var showsHistoryPane: Bool
    var showsCommitFooter: Bool

    init(_ section: Section) {
        showsHistoryPane = section == .history || section == .changes
        showsCommitFooter = section == .changes
    }
}
