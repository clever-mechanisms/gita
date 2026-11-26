import Darwin
import Foundation

/// Darwin packs attributes on four-byte boundaries. Read unaligned even for a 64-bit inode, timespec, or off_t.
struct DiskBulkRecord {
    var name: String
    var kind: fsobj_type_t
    var modifiedAt: Date?
    var inode: UInt64?
    var links: UInt32?
    var logical: UInt64
    var allocated: UInt64
    var entryError: UInt32

    init(_ record: UnsafeRawBufferPointer) throws {
        var cursor = BulkCursor(record: record)
        let returned = try cursor.take(attribute_set_t.self)
        entryError = try cursor.optional(UInt32.self, mask: returned.commonattr, bit: ATTR_CMN_ERROR) ?? 0
        if returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 {
            self.name = try Self.readName(&cursor, record: record)
        } else if entryError != 0 {
            self.name = ""
            kind = 0
            logical = 0
            allocated = 0
            return
        } else {
            throw CommandError.ioFailed(EIO)
        }
        if entryError != 0 {
            kind = 0
            logical = 0
            allocated = 0
            return
        }
        guard returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 else { throw CommandError.ioFailed(EIO) }
        kind = try cursor.take(fsobj_type_t.self)
        if let ts = try cursor.optional(timespec.self, mask: returned.commonattr, bit: ATTR_CMN_MODTIME) {
            modifiedAt = Date(timeIntervalSince1970: Double(ts.tv_sec) + Double(ts.tv_nsec) / 1_000_000_000)
        }
        inode = try cursor.optional(UInt64.self, mask: returned.commonattr, bit: ATTR_CMN_FILEID)
        links = try cursor.optional(UInt32.self, mask: returned.fileattr, bit: ATTR_FILE_LINKCOUNT)
        let size = try cursor.optional(off_t.self, mask: returned.fileattr, bit: ATTR_FILE_TOTALSIZE)
        let allocation = try cursor.optional(off_t.self, mask: returned.fileattr, bit: ATTR_FILE_ALLOCSIZE)
        logical = UInt64(clamping: size ?? 0)
        allocated = UInt64(clamping: allocation ?? size ?? 0)
    }

    private static func readName(_ cursor: inout BulkCursor, record: UnsafeRawBufferPointer) throws -> String {
        let referenceStart = cursor.offset
        let reference = try cursor.take(attrreference_t.self)
        let start = referenceStart + Int(reference.attr_dataoffset)
        let end = start + Int(reference.attr_length)
        guard start >= 0, end > start, end <= record.count, record[end - 1] == 0,
            let name = String(bytes: record[start..<(end - 1)], encoding: .utf8),
            !name.isEmpty, !name.contains("/"), name != ".", name != ".."
        else { throw CommandError.ioFailed(EILSEQ) }
        return name
    }
}

private struct BulkCursor {
    let record: UnsafeRawBufferPointer
    var offset = MemoryLayout<UInt32>.size

    mutating func take<T: BitwiseCopyable>(_ type: T.Type) throws -> T {
        guard offset + MemoryLayout<T>.size <= record.count else { throw CommandError.ioFailed(EIO) }
        defer { offset += MemoryLayout<T>.size }
        return record.loadUnaligned(fromByteOffset: offset, as: type)
    }

    mutating func optional<T: BitwiseCopyable>(_ type: T.Type, mask: attrgroup_t, bit: Int32) throws -> T? {
        try mask & attrgroup_t(bit) == 0 ? nil : take(type)
    }
}

struct DiskBulkReader {
    private static let skippableErrors: Set<Int32> = [ENOENT, EACCES, EPERM, ELOOP, ENAMETOOLONG, ENOTDIR]
    private var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    private var attributes = attrlist()

    init() {
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr =
            attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
            | attrgroup_t(ATTR_CMN_ERROR | ATTR_CMN_NAME | ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME | ATTR_CMN_FILEID)
        attributes.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT | ATTR_FILE_TOTALSIZE | ATTR_FILE_ALLOCSIZE)
    }

    static func isSkippable(_ code: Int32) -> Bool { skippableErrors.contains(code) }

    /// Returns `false` when a non-strict scan skipped an unreadable or vanishing directory.
    mutating func read(
        rootFD: Int32, relative: String, strict: Bool, check: () throws -> Void,
        visit: (DiskBulkRecord, Int32) throws -> Void
    ) throws -> Bool {
        let fd = openat(rootFD, relative.isEmpty ? "." : relative, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else {
            if !strict && Self.isSkippable(errno) { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(fd) }
        return try drain(fd: fd, strict: strict, check: check, visit: visit)
    }

    private mutating func drain(
        fd: Int32, strict: Bool, check: () throws -> Void, visit: (DiskBulkRecord, Int32) throws -> Void
    ) throws -> Bool {
        while true {
            try check()
            let count = getattrlistbulk(fd, &attributes, &buffer, buffer.count, 0)
            if count == 0 { return true }
            guard count > 0 else {
                if !strict && Self.isSkippable(errno) { return false }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            try parseBatch(count: Int(count), fd: fd, visit: visit)
        }
    }

    private func parseBatch(count: Int, fd: Int32, visit: (DiskBulkRecord, Int32) throws -> Void) throws {
        try buffer.withUnsafeBytes { bytes in
            var offset = 0
            for _ in 0..<count {
                guard offset + 4 <= bytes.count else { throw CommandError.ioFailed(EIO) }
                let size = Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                guard size >= 24, offset + size <= bytes.count else { throw CommandError.ioFailed(EIO) }
                let record = UnsafeRawBufferPointer(rebasing: bytes[offset..<(offset + size)])
                try visit(DiskBulkRecord(record), fd)
                offset += size
            }
        }
    }
}
