import GitaCore

/// The history header: its title names what the list shows, its tooltip what the graph leaves out, and the
/// All branches link shows whenever something narrower than every branch is on screen.
struct HistoryScopePresenter: Equatable {
    struct Input {
        /// The focused reference, only while the History page shows.
        var focused: GitReference?
        var filters: BranchFilters
        var references: [GitReference]
        var isSearching: Bool
        var searchField: HistorySearchField
        var searchQuery: String
        var authorLens: String?
        var branch: String?
    }

    var title: String
    var toolTip: String?
    var showsAllBranches: Bool
    var searchPlaceholder: String

    init(_ input: Input) {
        let names = Dictionary(input.references.map { ($0.fullName, $0.name) }, uniquingKeysWith: { first, _ in first })
        let only = input.filters.only.filter { names[$0] != nil }
        let filtered =
            only.count == 1
            ? names[only[0]] : only.count > 1 ? String(localized: "\(only.count) branches") : nil
        let searched = input.searchField == .author ? input.searchQuery : String(localized: "Search")
        let scope =
            input.focused?.name
            ?? (input.isSearching ? searched : input.authorLens ?? filtered ?? input.branch)
        title = scope.map { String(localized: "History · \($0)") } ?? String(localized: "History")
        let list = { (full: [String]) in full.compactMap { names[$0] }.joined(separator: ", ") }
        let filters = [
            only.count > 1 ? String(localized: "Shown alone: \(list(only))") : nil,
            input.filters.hidden.isEmpty ? nil : String(localized: "Hidden: \(list(input.filters.hidden))"),
        ].compactMap { $0 }
        if let focused = input.focused {
            toolTip = focused.fullName + "\n" + focused.commit
        } else {
            toolTip = input.isSearching || filters.isEmpty ? nil : filters.joined(separator: "\n")
        }
        showsAllBranches = input.focused != nil || input.isSearching || !only.isEmpty
        searchPlaceholder = String(localized: "Search \(input.searchField.localizedTitle)")
    }
}
