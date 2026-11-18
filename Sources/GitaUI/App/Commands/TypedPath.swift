import Foundation

/// A folder path typed into a prompt: `~` and `~user` at its start expand to that home folder, as in the shell.
enum TypedPath {
    static func url(_ text: String) -> URL { URL(fileURLWithPath: expandingTilde(text)) }

    static func expandingTilde(_ path: String) -> String {
        guard path.hasPrefix("~") else { return path }
        let slash = path.firstIndex(of: "/") ?? path.endIndex
        let user = String(path[path.index(after: path.startIndex)..<slash])
        let files = FileManager.default
        guard let home = user.isEmpty ? files.homeDirectoryForCurrentUser : files.homeDirectory(forUser: user) else {
            return path
        }
        return home.path + path[slash...]
    }
}
