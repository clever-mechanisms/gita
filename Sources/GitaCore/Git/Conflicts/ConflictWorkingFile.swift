import Darwin
import Foundation

/// A conflicted path's working file, read and replaced only through descriptors of its verified parent directory.
struct ConflictWorkingFile: Equatable {
    enum Kind { case missing, regular, symlink, special }

    static let contentLimit = 8 * 1_024 * 1_024
    static let symlinkLimit = 32_768
    static let missing = Self(kind: .missing, data: nil, size: 0, mode: 0, identity: "missing")

    var kind: Kind
    var data: Data?
    var size: Int
    var mode: mode_t
    var identity: String

    static func read(root: URL, path: String) throws -> Self {
        guard let parent = try SafeDirectoryWalk.openParent(root: root, path: path, create: false) else {
            return missing
        }
        defer { close(parent) }
        return try read(parent: parent, name: SafeDirectoryWalk.leafName(path))
    }

    /// The file's type, contents (regular files within the limit, symlink targets) and identity, unchanged from
    /// first stat to last.
    static func read(parent: Int32, name: String) throws -> Self {
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return missing }
            throw ConflictFileError.inspectWorkingFile
        }
        guard info.st_size >= 0, info.st_size <= Int.max else { throw GitError.invalidPath }
        let size = Int(info.st_size)
        let kind: Kind
        var data: Data?
        switch info.st_mode & S_IFMT {
        case S_IFREG:
            kind = .regular
            if size <= contentLimit { data = try readRegular(parent: parent, name: name, expected: info) }
        case S_IFLNK:
            kind = .symlink
            data = try readLink(parent: parent, name: name, size: size)
        default:
            kind = .special
        }
        var after = stat()
        guard fstatat(parent, name, &after, AT_SYMLINK_NOFOLLOW) == 0, FileIdentity.of(info) == FileIdentity.of(after)
        else { throw GitError.staleConflict }
        return Self(
            kind: kind, data: data, size: size, mode: info.st_mode, identity: FileIdentity.of(info))
    }

    private static func readRegular(parent: Int32, name: String, expected: stat) throws -> Data {
        let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw GitError.staleConflict }
        defer { close(descriptor) }
        try requireIdentity(descriptor, expected)
        let data = try DescriptorIO.readAll(descriptor, limit: contentLimit)
        try requireIdentity(descriptor, expected)
        return data
    }

    private static func requireIdentity(_ descriptor: Int32, _ expected: stat) throws {
        var current = stat()
        guard fstat(descriptor, &current) == 0, FileIdentity.of(current) == FileIdentity.of(expected) else {
            throw GitError.staleConflict
        }
    }

    private static func readLink(parent: Int32, name: String, size: Int) throws -> Data {
        guard size <= symlinkLimit else {
            throw UnsupportedConflictError.symbolicLinkTooLarge
        }
        var target = [CChar](repeating: 0, count: max(4_096, size + 1))
        let count = readlinkat(parent, name, &target, target.count)
        guard count >= 0, count < target.count else { throw GitError.staleConflict }
        return Data(bytes: target, count: count)
    }

    /// Replaces (or with nil `contents`, removes) the file, only if it is still exactly `self`. New contents are
    /// written to a temporary sibling and renamed over it.
    func replace(root: URL, path: String, contents: Data?, mode: GitFileMode) throws {
        guard let parent = try SafeDirectoryWalk.openParent(root: root, path: path, create: contents != nil) else {
            guard kind == .missing, contents == nil else { throw GitError.staleConflict }
            return
        }
        defer { close(parent) }
        let name = SafeDirectoryWalk.leafName(path)
        try requireUnchanged(parent: parent, name: name)
        guard let contents else {
            if kind != .missing, unlinkat(parent, name, 0) != 0 {
                throw ConflictFileError.removeFile
            }
            return
        }
        let temporary = ".gita-resolution-" + UUID().uuidString
        var ownsTemporary = false
        defer { if ownsTemporary { _ = unlinkat(parent, temporary, 0) } }
        if mode == .symlink {
            try Self.writeSymlink(contents, parent: parent, name: temporary)
            ownsTemporary = true
        } else {
            try Self.writeFile(contents, parent: parent, name: temporary, executable: mode == .executable)
            ownsTemporary = true
        }
        try requireUnchanged(parent: parent, name: name)
        let renamed =
            kind == .missing
            ? renameatx_np(parent, temporary, parent, name, UInt32(RENAME_EXCL))
            : renameat(parent, temporary, parent, name)
        guard renamed == 0 else {
            throw ConflictFileError.replaceFile
        }
        ownsTemporary = false
    }

    private func requireUnchanged(parent: Int32, name: String) throws {
        let current = try Self.read(parent: parent, name: name)
        guard current.identity == identity, current.data == data else { throw GitError.staleConflict }
    }

    private static func writeSymlink(_ contents: Data, parent: Int32, name: String) throws {
        guard !contents.isEmpty, !contents.contains(GitOutput.nul), contents.count <= symlinkLimit else {
            throw UnsupportedConflictError.invalidSymbolicLinkTarget
        }
        let target = contents.map { CChar(bitPattern: $0) } + [0]
        guard symlinkat(target, parent, name) == 0 else {
            throw ConflictFileError.prepareSymbolicLink
        }
    }

    /// A new private file with the given contents, removed again when writing fails.
    private static func writeFile(_ contents: Data, parent: Int32, name: String, executable: Bool) throws {
        let descriptor = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw ConflictFileError.prepareResult
        }
        defer { close(descriptor) }
        do {
            try DescriptorIO.writeAll(
                contents, to: descriptor,
                failure: ConflictFileError.writeResult)
            guard fchmod(descriptor, executable ? 0o755 : 0o644) == 0, fsync(descriptor) == 0 else {
                throw ConflictFileError.finishWritingResult
            }
        } catch {
            _ = unlinkat(parent, name, 0)
            throw error
        }
    }
}
