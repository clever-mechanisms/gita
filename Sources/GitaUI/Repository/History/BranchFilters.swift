import Foundation
import GitaCore

/// The sidebar's per-branch marks: pinned to the top of its group, shown alone in the graph, or hidden
/// from it. Full reference names; kept per repository (its common Git directory, so every worktree shares them).
struct BranchFilters: Codable, Equatable {
    enum Kind { case pin, only, hide }
    var pinned: [String] = []
    var only: [String] = []
    var hidden: [String] = []

    var scope: HistoryScope { HistoryScope(only: only, hidden: hidden) }
    var isFiltering: Bool { !only.isEmpty || !hidden.isEmpty }
    func contains(_ kind: Kind, _ fullName: String) -> Bool {
        switch kind {
        case .pin: pinned.contains(fullName)
        case .only: only.contains(fullName)
        case .hide: hidden.contains(fullName)
        }
    }
    /// Showing a branch alone un-hides it, and hiding one takes it out of the shown-alone set.
    mutating func toggle(_ kind: Kind, _ fullName: String) {
        func flip(_ list: inout [String]) {
            if let index = list.firstIndex(of: fullName) { list.remove(at: index) } else { list.append(fullName) }
        }
        switch kind {
        case .pin: flip(&pinned)
        case .only:
            flip(&only)
            if only.contains(fullName) { hidden.removeAll { $0 == fullName } }
        case .hide:
            flip(&hidden)
            if hidden.contains(fullName) { only.removeAll { $0 == fullName } }
        }
    }

    private static let key = "branchFilters"
    static func load(_ repository: URL, from defaults: UserDefaults) -> Self {
        guard let data = (defaults.dictionary(forKey: key) as? [String: Data])?[repository.standardizedFileURL.path],
            let filters = try? JSONDecoder().decode(Self.self, from: data)
        else { return Self() }
        return filters
    }
    func save(_ repository: URL, to defaults: UserDefaults) {
        var all = defaults.dictionary(forKey: Self.key) as? [String: Data] ?? [:]
        all[repository.standardizedFileURL.path] = self == Self() ? nil : try? JSONEncoder().encode(self)
        defaults.set(all, forKey: Self.key)
    }
}

extension Notification.Name {
    /// Posted with the repository's common Git directory as the object: other tabs of that repository reload them.
    static let gitaBranchFiltersChanged = Notification.Name("dev.clevermechanisms.Gita.branchFiltersChanged")
}
