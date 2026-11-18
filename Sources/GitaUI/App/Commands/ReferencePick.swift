import GitaCore

/// The Merge and Rebase pickers' choices: every reference but the current branch, by name.
struct ReferencePick {
    let references: [GitReference]

    init(references: [GitReference]) { self.references = references.filter { !$0.isCurrent } }

    var names: [String] { references.map(\.name) }

    /// The reference to preselect: `preselect` (a full name) when listed, else main or master.
    func initialIndex(preselect: String?) -> Int? {
        if let preselect, let index = references.firstIndex(where: { $0.fullName == preselect }) { return index }
        return references.firstIndex { $0.name == "main" || $0.name == "master" }
    }

    /// What to merge or rebase onto: the listed reference's full name, or the typed text (a commit, a ref).
    func resolve(selectedIndex: Int, text: String) -> String {
        references.indices.contains(selectedIndex) && text == references[selectedIndex].name
            ? references[selectedIndex].fullName : text
    }
}
