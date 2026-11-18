import Foundation

/// Tab names: the repository's folder name, with its parent folder when another tab's repository has the same name.
/// A linked worktree's tab reads "repository [worktree]"; where the worktree's folder repeats the repository's name
/// ("app-windows" beside "app"), the open tab spells it out and the others shorten it to "app […-windows]".
struct TabTitles {
    struct Entry {
        /// The tab's repository (an author tab's too).
        var root: URL?
        /// The repository of a repository tab; nil for author tabs.
        var repositoryRoot: URL?
        /// The main checkout, when `root` is one of its linked worktrees.
        var mainCheckout: URL?
    }
    private let entries: [Entry]

    init(_ entries: [Entry]) { self.entries = entries }

    func name(at index: Int, isLoading: Bool, selected: Bool = false) -> String {
        guard entries.indices.contains(index), let root = entries[index].root else {
            return isLoading ? String(localized: "Loading Repository") : String(localized: "Open Repository")
        }
        if let main = entries[index].mainCheckout {
            // A bare repository's folder ("app.git") names the repository without its extension.
            let repository =
                main.pathExtension == "git" ? main.deletingPathExtension().lastPathComponent : main.lastPathComponent
            let worktree = selected ? root.lastPathComponent : Self.short(root.lastPathComponent, after: repository)
            return "\(repository) [\(worktree)]"
        }
        let name = root.lastPathComponent
        let clashes = entries.indices.contains { other in
            other != index && entries[other].repositoryRoot?.lastPathComponent == name
                && entries[other].repositoryRoot != root && entries[other].mainCheckout == nil
        }
        return clashes ? root.deletingLastPathComponent().lastPathComponent + "/" + name : name
    }

    /// The worktree's folder without the repository's name it starts with: "app-windows" after "app" is "…-windows".
    static func short(_ worktree: String, after repository: String) -> String {
        guard !repository.isEmpty, worktree.count > repository.count,
            worktree.lowercased().hasPrefix(repository.lowercased())
        else { return worktree }
        return "…" + worktree.dropFirst(repository.count)
    }
}
