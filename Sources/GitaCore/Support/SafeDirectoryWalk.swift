import Darwin
import Foundation

/// Opens directories one no-follow component at a time, so a symlink can never redirect a read or write into an
/// unrelated repository or an external target.
enum SafeDirectoryWalk {
    static let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    /// The descriptor of `path`'s parent directory under `root`. Nil when an ancestor is missing and `create` is
    /// false; with `create`, missing ancestors are made.
    static func openParent(root: URL, path: String, create: Bool) throws -> Int32? {
        var descriptor = open(root.path, directoryFlags)
        guard descriptor >= 0 else { throw GitError.invalidPath }
        do {
            for component in path.split(separator: "/").dropLast() {
                guard let next = try openChild(String(component), in: descriptor, create: create) else {
                    close(descriptor)
                    return nil
                }
                close(descriptor)
                descriptor = next
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private static func openChild(_ name: String, in parent: Int32, create: Bool) throws -> Int32? {
        var next = openat(parent, name, directoryFlags)
        if next < 0, errno == ENOENT, create {
            guard mkdirat(parent, name, 0o755) == 0 || errno == EEXIST else {
                throw ConflictFileError.createDirectory
            }
            next = openat(parent, name, directoryFlags)
        }
        guard next >= 0 else {
            if errno == ENOENT, !create { return nil }
            throw GitError.invalidPath
        }
        return next
    }

    /// The last path component, the name opened relative to `openParent`'s descriptor.
    /// The last path component, ignoring trailing slashes (`a/b/` is `b`, `/` stays `/`).
    static func leafName(_ path: String) -> String {
        var trimmed = Substring(path)
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        guard trimmed != "/", let slash = trimmed.lastIndex(of: "/") else { return String(trimmed) }
        return String(trimmed[trimmed.index(after: slash)...])
    }
}
