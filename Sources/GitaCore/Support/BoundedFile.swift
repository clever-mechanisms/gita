import Darwin
import Foundation

/// Reads Git metadata files: regular files only (a symlink is refused, never followed), bounded in size, and
/// unchanged from open to end of read.
struct BoundedFile {
    static let metadataLimit = 1_024 * 1_024

    var data: Data
    var identity: String

    /// Nil when the file does not exist.
    static func read(_ url: URL, limit: Int = metadataLimit) throws -> Self? {
        try read(parent: AT_FDCWD, path: url.path, limit: limit)
    }

    static func read(parent: Int32, path: String, limit: Int) throws -> Self? {
        let descriptor = openat(parent, path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw LocalFileError.metadataUnreadable
        }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size >= 0,
            before.st_size <= limit
        else {
            throw LocalFileError.metadataNotBounded
        }
        let data = try DescriptorIO.readAll(descriptor, limit: limit)
        var after = stat()
        guard fstat(descriptor, &after) == 0, FileIdentity.of(before) == FileIdentity.of(after) else {
            throw GitError.operationChanged
        }
        return Self(data: data, identity: FileIdentity.of(after))
    }

    /// The contents only; nil when the file does not exist.
    static func contents(_ url: URL, limit: Int = metadataLimit) throws -> Data? { try read(url, limit: limit)?.data }

    /// True for a real directory, false when nothing is there; anything else at that path is refused.
    static func directoryExists(
        _ url: URL, failure: @autoclosure () -> any Error, notDirectory: @autoclosure () -> any Error
    )
        throws -> stat?
    {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw failure()
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw notDirectory() }
        return info
    }
}
