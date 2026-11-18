import Darwin
import Foundation

/// Reads a checkout's `.vercel/project.json` without following symlinks. Project-link identifiers are local
/// routing metadata, not CLI credentials; authentication files are never opened.
enum VercelLinkReader {
    private static let maximumPath = 32_768
    private static let maximumFile = 16 * 1_024
    private static let maximumIdentifier = 128
    private static let identifierCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
    private static let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    /// Whether the checkout declares a link at all. Only a proven absence permits the sibling fallback: a broken
    /// symlink, an unreadable directory or any other declared entry fails closed.
    static func isDeclared(at root: URL) -> Bool {
        guard let rootFD = openRoot(root) else { return true }
        defer { close(rootFD) }
        var entry = stat()
        guard fstatat(rootFD, ".vercel", &entry, AT_SYMLINK_NOFOLLOW) == 0 else { return errno != ENOENT }
        guard entry.st_mode & S_IFMT == S_IFDIR else { return true }
        let linkFD = openat(rootFD, ".vercel", directoryFlags)
        guard linkFD >= 0 else { return true }
        defer { close(linkFD) }
        if fstatat(linkFD, "project.json", &entry, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        return errno != ENOENT
    }

    /// `vercel:<org>/<project>` from a regular, bounded `project.json` that did not change while it was read.
    static func sourceID(at root: URL) -> String? {
        guard let rootFD = openRoot(root) else { return nil }
        defer { close(rootFD) }
        let linkFD = openat(rootFD, ".vercel", directoryFlags)
        guard linkFD >= 0 else { return nil }
        defer { close(linkFD) }
        let fd = openat(linkFD, "project.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard let data = readStable(fd), let link = try? JSONDecoder().decode(Link.self, from: data),
            isIdentifier(link.orgId), isIdentifier(link.projectId), link.projectId.hasPrefix("prj_"),
            link.projectId.count > 4
        else { return nil }
        return VercelLink.sourceID(org: link.orgId, project: link.projectId)
    }

    private static func openRoot(_ root: URL) -> Int32? {
        guard root.isFileURL, root.path.utf8.count <= maximumPath, !root.path.contains("\0") else { return nil }
        let fd = open(root.standardizedFileURL.resolvingSymlinksInPath().path, directoryFlags)
        return fd >= 0 ? fd : nil
    }

    private static func readStable(_ fd: Int32) -> Data? {
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size > 0,
            before.st_size <= maximumFile, let data = readBounded(fd)
        else { return nil }
        var after = stat()
        guard fstat(fd, &after) == 0, isSameVersion(before, after) else { return nil }
        return data
    }

    private static func readBounded(_ fd: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while data.count <= maximumFile {
            let count = buffer.withUnsafeMutableBytes {
                read(fd, $0.baseAddress, min($0.count, maximumFile + 1 - data.count))
            }
            if count < 0 { return nil }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data.count <= maximumFile ? data : nil
    }

    private static func isSameVersion(_ before: stat, _ after: stat) -> Bool {
        before.st_dev == after.st_dev && before.st_ino == after.st_ino && before.st_size == after.st_size
            && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
            && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
            && before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec
            && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    }

    private static func isIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumIdentifier
            && ProviderValidation.consists(value, of: identifierCharacters)
    }

    private struct Link: Decodable {
        let orgId: String
        let projectId: String
    }
}
