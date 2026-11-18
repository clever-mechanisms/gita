import Darwin
import Foundation

/// The identity of every tracked working path a reset can overwrite: its stat identity (which changes with any
/// write) and, for a symbolic link, its target. Contents are not read, so the review costs one `lstat` per path.
enum WorkingTreeFingerprint {
    static let pathLimit = 100_000

    static func add(root: URL, paths: [String], to identity: inout Fingerprint) throws {
        guard paths.count <= pathLimit else {
            throw TrackedFileError.fileLimit
        }
        var rootInfo = stat()
        guard lstat(root.path, &rootInfo) == 0 else { throw GitError.invalidPath }
        identity.add("root-identity", FileIdentity.of(rootInfo, includeModification: false))
        for path in paths {
            try Task.checkCancellation()
            identity.add("path", path)
            guard let parent = try SafeDirectoryWalk.openParent(root: root, path: path, create: false) else {
                identity.add("missing", Data())
                continue
            }
            defer { close(parent) }
            try add(parent: parent, name: SafeDirectoryWalk.leafName(path), to: &identity)
        }
    }

    private static func add(parent: Int32, name: String, to identity: inout Fingerprint) throws {
        var before = stat()
        guard fstatat(parent, name, &before, AT_SYMLINK_NOFOLLOW) == 0 else {
            guard errno == ENOENT else {
                throw TrackedFileError.uninspectable
            }
            identity.add("missing", Data())
            return
        }
        identity.add("working-identity", FileIdentity.of(before))
        switch before.st_mode & S_IFMT {
        case S_IFREG, S_IFDIR: break
        case S_IFLNK: identity.add("link", try linkTarget(parent: parent, name: name))
        default: throw TrackedFileError.specialFile
        }
        var after = stat()
        guard fstatat(parent, name, &after, AT_SYMLINK_NOFOLLOW) == 0, FileIdentity.of(before) == FileIdentity.of(after)
        else { throw TrackedFileError.changedDuringReview }
    }

    private static func linkTarget(parent: Int32, name: String) throws -> Data {
        var bytes = [CChar](repeating: 0, count: ConflictWorkingFile.symlinkLimit + 1)
        let count = readlinkat(parent, name, &bytes, bytes.count)
        guard count >= 0, count < bytes.count else {
            throw TrackedFileError.symbolicLinkUnreadable
        }
        return Data(bytes: bytes, count: count)
    }
}
