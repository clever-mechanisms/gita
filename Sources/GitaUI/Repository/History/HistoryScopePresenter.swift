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
        var highlightedAuthor: CommitAuthor?
        var inlineAuthor: CommitAuthor?
        var branch: String?
    }

    var title: String
    var toolTip: String?
    var searchPlaceholder: String
    var historyFilters: HistoryFilters

    init(_ input: Input) {
        let names = Dictionary(input.references.map { ($0.fullName, $0.name) }, uniquingKeysWith: { first, _ in first })
        let only = input.filters.only.filter { names[$0] != nil }
        let scope = Self.resolveScopeName(input, names: names, only: only)
        title = scope.map { String(localized: "History · \($0)") } ?? String(localized: "History")
        toolTip = Self.resolveToolTip(input, names: names, only: only)
        searchPlaceholder = String(localized: "Search \(input.searchField.localizedTitle)")
        historyFilters = Self.resolveFilters(input)
    }

    private static func resolveScopeName(_ input: Input, names: [String: String], only: [String]) -> String? {
        if let focused = input.focused { return focused.name }
        if input.isSearching {
            return input.searchField == .author ? input.searchQuery : String(localized: "Search")
        }
        if let authorName = input.inlineAuthor?.name ?? input.authorLens { return authorName }
        if only.count == 1 { return names[only[0]] }
        if only.count > 1 { return String(localized: "\(only.count) branches") }
        return input.branch
    }

    private static func resolveToolTip(_ input: Input, names: [String: String], only: [String]) -> String? {
        if let focused = input.focused { return focused.fullName + "\n" + focused.commit }
        guard !input.isSearching else { return nil }
        let list = { (full: [String]) in full.compactMap { names[$0] }.joined(separator: ", ") }
        let filters = [
            only.count > 1 ? String(localized: "Shown alone: \(list(only))") : nil,
            input.filters.hidden.isEmpty ? nil : String(localized: "Hidden: \(list(input.filters.hidden))"),
        ].compactMap { $0 }
        return filters.isEmpty ? nil : filters.joined(separator: "\n")
    }

    private static func resolveFilters(_ input: Input) -> HistoryFilters {
        let scopeChoice = HistoryFilters.resolveScope(
            focused: input.focused, filters: input.filters, references: input.references, branch: input.branch)
        let authorFilter: HistoryFilters.AuthorFilter? =
            if let inlineAuthor = input.inlineAuthor {
                HistoryFilters.AuthorFilter(author: inlineAuthor, mode: .filter)
            } else if let highlighted = input.highlightedAuthor {
                HistoryFilters.AuthorFilter(author: highlighted, mode: .highlight)
            } else {
                nil
            }
        let searchFilter =
            input.isSearching && !input.searchQuery.isEmpty
            ? HistoryFilters.SearchFilter(field: input.searchField, query: input.searchQuery) : nil
        return HistoryFilters(scope: scopeChoice, author: authorFilter, search: searchFilter)
    }
}
