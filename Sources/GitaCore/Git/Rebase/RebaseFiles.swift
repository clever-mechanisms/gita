import Darwin
import Foundation

/// Descriptor-relative, no-follow access for every directory component. Private
/// session files must be owned by this user and may not be hard-linked or shared.
enum RebaseFiles {
    static func openDirectory(_ url: URL) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0") else {
            throw RebasePlanError.planChanged
        }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw RebasePlanError.planChanged }
        do {
            for component in url.path.split(separator: "/") {
                guard component != ".", component != ".." else { throw RebasePlanError.planChanged }
                let next = openat(current, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw RebasePlanError.planChanged }
                close(current)
                current = next
            }
            var info = stat()
            guard fstat(current, &info) == 0, info.st_uid == getuid() else {
                throw RebaseHistoryError.worktreeNotOwned
            }
            return current
        } catch {
            close(current)
            throw error
        }
    }

    /// The absolute path with `.` and empty components dropped and `..` applied, without touching the filesystem.
    /// Foundation's standardizing also rewrites /private/var, /private/tmp and /private/etc to their symlinks,
    /// which this no-follow walk refuses and Git never passes.
    static func lexicalPath(_ url: URL) -> String {
        var components: [Substring] = []
        for component in url.absoluteURL.path.split(separator: "/") {
            switch component {
            case ".": continue
            case "..": _ = components.popLast()
            default: components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }

    static func identity(_ fd: Int32) throws -> String {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw RebasePlanError.planChanged }
        return FileIdentity.of(info, includeModification: false)
    }
    static func directoryIdentity(_ url: URL) throws -> String {
        let fd = try openDirectory(url)
        defer { close(fd) }
        return try identity(fd)
    }
    static func optionalDirectory(parent: Int32, name: String) throws -> Int32? {
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw RebasePlanError.planChanged
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid() else {
            close(fd)
            throw RebasePlanError.planChanged
        }
        return fd
    }
    static func requiredDirectory(parent: Int32, name: String) throws -> Int32 {
        guard let fd = try optionalDirectory(parent: parent, name: name) else { throw RebasePlanError.planChanged }
        return fd
    }
    static func privateDirectory(
        parent: Int32, name: String, create: Bool = false, exclusive: Bool = false
    ) throws -> Int32 {
        if create, mkdirat(parent, name, 0o700) != 0, errno != EEXIST || exclusive { throw RebasePlanError.planChanged }
        let fd = try requiredDirectory(parent: parent, name: name)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & 0o077 == 0 else {
            close(fd)
            throw RebasePlanError.planChanged
        }
        return fd
    }
    static func read(parent: Int32, name: String, limit: Int, privateFile: Bool = false) throws -> Data? {
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw RebasePlanError.planChanged
        }
        defer { close(fd) }
        var before = stat()
        var after = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_uid == getuid(),
            before.st_nlink == 1,
            before.st_size >= 0, before.st_size <= limit, !privateFile || before.st_mode & 0o077 == 0
        else { throw RebasePlanError.planChanged }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw RebasePlanError.planChanged
            }
            guard data.count + count <= limit else { throw RebasePlanError.planChanged }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard fstat(fd, &after) == 0, FileIdentity.of(before) == FileIdentity.of(after) else {
            throw GitError.operationChanged
        }
        return data
    }
    static func create(_ data: Data, parent: Int32, name: String) throws {
        let fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RebasePlanError.planChanged }
        defer { close(fd) }
        do { try write(data, descriptor: fd) } catch {
            _ = unlinkat(parent, name, 0)
            throw error
        }
    }
    static func replace(_ data: Data, parent: Int32, name: String, limit: Int) throws {
        guard data.count <= limit else { throw RebasePlanError.planChanged }
        let fd = openat(parent, name, O_WRONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw RebasePlanError.planChanged }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
            info.st_size >= 0, info.st_size <= limit, ftruncate(fd, 0) == 0
        else { throw RebasePlanError.planChanged }
        try write(data, descriptor: fd)
    }
    private static func write(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let start = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, start.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw RebasePlanError.planChanged
                }
                guard count > 0 else { throw RebasePlanError.planChanged }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw RebasePlanError.planChanged }
    }
}
