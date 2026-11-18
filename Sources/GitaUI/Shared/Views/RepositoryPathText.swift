import Foundation

/// Parts of a repository-relative path (`Sources/App/main.swift`), as Git prints it: `/`-separated, no leading or
/// trailing slash.
enum RepositoryPathText {
    /// `main.swift`.
    static func name(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
    /// `Sources/App`; empty for a top-level file.
    static func folder(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }
    /// `swift`, lowercased; empty without an extension.
    static func fileExtension(_ path: String) -> String {
        URL(fileURLWithPath: name(path)).pathExtension.lowercased()
    }
}
