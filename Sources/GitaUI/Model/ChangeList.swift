import GitaCore

/// The Changes page's list: conflicts first, then the staged or the unstaged files, each in Git's path order
/// (never sorted on the main actor, however large the working tree).
enum ChangeList {
    static func files(_ changes: [FileChange], staged: Bool) -> [FileChange] {
        var files = changes.filter(\.isConflict)
        files.append(contentsOf: changes.lazy.filter { !$0.isConflict && (staged ? $0.isStaged : $0.isUnstaged) })
        return files
    }
}
