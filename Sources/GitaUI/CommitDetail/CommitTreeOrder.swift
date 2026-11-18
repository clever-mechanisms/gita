import GitaCore

/// How the commit file tree orders and finds its entries, without a view.
enum CommitTreeOrder {
    /// What a Git tree entry is, from `git ls-tree`'s object type.
    enum Kind: Equatable {
        case folder, submodule, file
        init(_ entry: TreeEntry) {
            switch entry.kind {
            case "tree": self = .folder
            case "commit": self = .submodule
            default: self = .file
            }
        }
        var symbol: String {
            switch self {
            case .folder: "folder"
            case .submodule: "shippingbox"
            case .file: "doc.text"
            }
        }
    }

    /// Folders first, then everything else, each in Finder's order.
    static func sorted(_ entries: [TreeEntry]) -> [TreeEntry] {
        entries.sorted {
            let folders = (Kind($0) == .folder, Kind($1) == .folder)
            if folders.0 != folders.1 { return folders.0 }
            return $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    /// The paths from the top folder down to `path` itself: `a`, `a/b`, `a/b/c.txt`.
    static func pathPrefixes(_ path: String) -> [String] {
        var prefix = ""
        return path.split(separator: "/").map { part in
            prefix = prefix.isEmpty ? String(part) : prefix + "/" + part
            return prefix
        }
    }
}
