import Foundation

/// Where a checkout keeps its Git data, read from disk without running Git. A main checkout's `.git` is a folder;
/// a linked worktree's `.git` is a file naming its own folder (`gitdir: …/.git/worktrees/name`), whose `commondir`
/// leads back to the shared folder with the refs.
public enum GitDirectoryLocator {
    public struct Location: Equatable, Sendable {
        /// HEAD and the index.
        public let gitDirectory: URL
        /// Refs and packed refs; the same as `gitDirectory` in a main checkout.
        public let commonDirectory: URL

        public init(gitDirectory: URL, commonDirectory: URL) {
            self.gitDirectory = gitDirectory
            self.commonDirectory = commonDirectory
        }
    }

    private static let fileLimit = 4_096

    public static func locate(checkout root: URL, fileManager: FileManager = .default) -> Location? {
        let dotGit = root.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return Location(gitDirectory: dotGit, commonDirectory: dotGit) }
        guard let gitDirectory = pointer(in: dotGit, prefix: "gitdir:", base: root),
            fileManager.fileExists(atPath: gitDirectory.path)
        else { return nil }
        let common =
            pointer(in: gitDirectory.appendingPathComponent("commondir"), prefix: "", base: gitDirectory)
            ?? gitDirectory
        return Location(gitDirectory: gitDirectory, commonDirectory: common)
    }

    /// The path on the first line of `file` after `prefix`, resolved against `base` when relative.
    private static func pointer(in file: URL, prefix: String, base: URL) -> URL? {
        guard let data = try? Data(contentsOf: file), data.count <= fileLimit,
            let text = String(bytes: data, encoding: .utf8), let line = text.split(whereSeparator: \.isNewline).first,
            line.hasPrefix(prefix)
        else { return nil }
        let path = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)
        return url.standardizedFileURL
    }
}
