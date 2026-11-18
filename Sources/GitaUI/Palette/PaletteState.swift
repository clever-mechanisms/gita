import Foundation

/// A row of the palette's list: a section's heading, or a result.
enum PaletteRow: Equatable {
    /// `more` results of the kind are left out (its own scope shows them).
    case header(PaletteKind, more: Int)
    case result(PaletteResult)

    var result: PaletteResult? {
        if case .result(let result) = self { result } else { nil }
    }
}

/// The palette without its window: the items, what is typed and the scope give the rows and the selected one.
///
/// Nothing typed: each kind's items in their own order, the recently chosen first. Something typed: every word must
/// be found in an item; the best matches first, and the section holding the best match first.
struct PaletteState {
    private(set) var entries: [PaletteEntry] = []
    private(set) var query = ""
    /// The kind shown alone; nil shows all of them.
    private(set) var scope: PaletteKind?
    private(set) var rows: [PaletteRow] = []
    /// The selected row; nil while nothing is found.
    private(set) var selection: Int?
    /// Ids of the items chosen before, the latest first.
    var recents: [String] = []

    init(scope: PaletteKind? = nil) { self.scope = scope }

    /// The scopes offered: all, then each kind that has items.
    var scopes: [PaletteKind?] {
        let present = Set(entries.map(\.item.kind))
        return [nil] + PaletteKind.allCases.filter(present.contains)
    }

    var selectedItem: PaletteItem? { selection.flatMap { rows[$0].result?.item } }

    /// New items (a branch's date arrived, a provider answered): the selected item stays selected if it is still
    /// listed.
    mutating func update(_ items: [PaletteItem]) {
        let selected = selectedItem?.id
        entries = items.map(PaletteEntry.init)
        if let scope, !scopes.contains(scope) { self.scope = nil }
        rebuild(keeping: selected)
    }

    mutating func setQuery(_ text: String) {
        guard text != query else { return }
        query = text
        rebuild(keeping: nil)
    }

    mutating func setScope(_ next: PaletteKind?) {
        guard next != scope, scopes.contains(next) else { return }
        scope = next
        rebuild(keeping: nil)
    }

    /// Tab and ⇧Tab: the next or previous scope, around the ends.
    mutating func cycleScope(forward: Bool) {
        let scopes = scopes
        guard let index = scopes.firstIndex(of: scope) else { return }
        setScope(scopes[(index + (forward ? 1 : scopes.count - 1)) % scopes.count])
    }

    /// ↑ and ↓: the next result that way, past the headings; it stops at the ends.
    mutating func move(by step: Int) {
        guard var index = selection else { return }
        while rows.indices.contains(index + step) {
            index += step
            if rows[index].result != nil {
                selection = index
                return
            }
        }
    }

    // MARK: Rows

    private mutating func rebuild(keeping selected: String?) {
        let tokens = PaletteText.tokens(query)
        var sections: [(kind: PaletteKind, results: [PaletteResult])] = []
        for kind in PaletteKind.allCases where scope == nil || scope == kind {
            let results = ranked(kind, tokens: tokens)
            if !results.isEmpty { sections.append((kind, results)) }
        }
        if !tokens.isEmpty {
            // Stable: sections as good as each other keep their usual order.
            sections.sort { PaletteEntry.band($0.results[0].score) < PaletteEntry.band($1.results[0].score) }
        }
        rows = sections.flatMap { section -> [PaletteRow] in
            let limit = scope == nil ? section.kind.sharedLimit(hasQuery: !tokens.isEmpty) : PaletteKind.scopedLimit
            let shown = section.results.prefix(limit)
            guard !shown.isEmpty else { return [] }
            return [.header(section.kind, more: section.results.count - shown.count)] + shown.map(PaletteRow.result)
        }
        selection = selected.flatMap { id in rows.firstIndex { $0.result?.item.id == id } } ?? firstChoice
    }

    /// The kind's results, best first: by score, then those that can run, then the recently chosen, then their own
    /// order.
    private func ranked(_ kind: PaletteKind, tokens: [[Character]]) -> [PaletteResult] {
        let found = entries.filter { $0.item.kind == kind }.compactMap { $0.result(for: tokens) }
        let recency = Dictionary(recents.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let keys = found.map { result in
            [result.score, result.item.isEnabled ? 0 : 1, recency[result.item.id] ?? recents.count]
        }
        return found.indices.sorted { keys[$0].lexicographicallyPrecedes(keys[$1]) || keys[$0] == keys[$1] && $0 < $1 }
            .map { found[$0] }
    }

    /// The row selected at first: the first that can run and is not where the user already is.
    private var firstChoice: Int? {
        rows.firstIndex { $0.result.map { $0.item.isEnabled && !$0.item.isCurrent } ?? false }
            ?? rows.firstIndex { $0.result != nil }
    }
}
