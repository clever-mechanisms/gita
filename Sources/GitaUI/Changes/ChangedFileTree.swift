import Foundation
import GitaCore

/// Which status column of a change a list shows.
enum ChangedFileSide: Sendable {
    case unstaged, staged, commit
}

/// A row of a changed-files list: a folder (no `file`) or a file. A class, because the outline view identifies its
/// items by reference.
final class ChangedFileNode: NSObject {
    let name: String
    /// The folder's or file's repository-relative path.
    let path: String
    let file: FileChange?
    var children: [ChangedFileNode] = []
    init(name: String, path: String, file: FileChange?) {
        self.name = name
        self.path = path
        self.file = file
    }
    var isFolder: Bool { file == nil }

    /// The files of this row: itself, or every file inside the folder.
    var files: [FileChange] {
        if let file { return [file] }
        return children.flatMap(\.files)
    }
}

/// The badge of a change: its letter, what it means, and the words VoiceOver reads.
struct ChangedFileStatus: Equatable {
    enum Kind: Equatable { case conflict, added, deleted, renamed, copied, typeChanged, modified }
    let kind: Kind

    var letter: String {
        switch kind {
        case .conflict: "!"
        case .added: "+"
        case .deleted: "−"
        case .renamed: "R"
        case .copied: "C"
        case .typeChanged: "T"
        case .modified: "M"
        }
    }
    var spoken: String {
        switch kind {
        case .conflict: String(localized: "Conflict")
        case .added: String(localized: "Added")
        case .deleted: String(localized: "Deleted")
        case .renamed: String(localized: "Renamed")
        case .copied: String(localized: "Copied")
        case .typeChanged: String(localized: "Type changed")
        case .modified: String(localized: "Modified")
        }
    }

    /// The status of `file` on `side`: a conflict wins, then Git's status letter for that side.
    init(_ file: FileChange, side: ChangedFileSide) {
        if file.isConflict {
            kind = .conflict
            return
        }
        let code: FileChange.Code
        switch side {
        case .unstaged: code = file.worktreeCode
        case .staged: code = file.indexCode
        case .commit: code = file.indexCode == .unmodified ? file.worktreeCode : file.indexCode
        }
        kind = Self.kinds[code] ?? .modified
    }
    private static let kinds: [FileChange.Code: Kind] = [
        .added: .added, .untracked: .added, .deleted: .deleted, .renamed: .renamed, .copied: .copied,
        .typeChanged: .typeChanged,
    ]
}

/// The rows of a changed-files list, built without a view.
enum ChangedFileTree {
    /// Files whose path (or original path, for a rename) contains `query`; all of them for an empty query.
    static func filter(_ files: [FileChange], query: String) -> [FileChange] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return files }
        return files.filter {
            $0.path.localizedStandardContains(trimmed) || ($0.originalPath?.localizedStandardContains(trimmed) ?? false)
        }
    }

    /// One row per file, named by its last path component.
    static func flat(_ files: [FileChange], index: inout [String: ChangedFileNode]) -> [ChangedFileNode] {
        files.map { file in
            let node = ChangedFileNode(name: RepositoryPathText.name(file.path), path: file.path, file: file)
            index[file.path] = node
            return node
        }
    }

    /// Folders first, then files, each in Finder's order; a folder is one path component.
    static func tree(_ files: [FileChange], index: inout [String: ChangedFileNode]) -> [ChangedFileNode] {
        let root = ChangedFileNode(name: "", path: "", file: nil)
        var folders: [String: ChangedFileNode] = ["": root]
        for file in files {
            let parts = file.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            let parent = folder(for: parts.dropLast(), under: root, folders: &folders, index: &index)
            let node = ChangedFileNode(name: parts.last ?? file.path, path: file.path, file: file)
            index[file.path] = node
            parent.children.append(node)
        }
        sort(root)
        return root.children
    }

    /// The folder at `parts` below `root`, creating the missing levels.
    private static func folder(
        for parts: ArraySlice<String>, under root: ChangedFileNode, folders: inout [String: ChangedFileNode],
        index: inout [String: ChangedFileNode]
    ) -> ChangedFileNode {
        var parent = root
        var path = ""
        for part in parts {
            path = path.isEmpty ? part : path + "/" + part
            if let folder = folders[path] {
                parent = folder
                continue
            }
            let folder = ChangedFileNode(name: part, path: path, file: nil)
            folders[path] = folder
            index[path] = folder
            parent.children.append(folder)
            parent = folder
        }
        return parent
    }

    private static func sort(_ node: ChangedFileNode) {
        node.children.sort { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        for child in node.children where child.isFolder { sort(child) }
    }
}
