import Foundation

/// `git status --porcelain=v2 [--branch] -z`, read byte by byte: one String per path and none per field, so a
/// 50,000-entry working tree parses in a few milliseconds.
struct StatusParser {
    struct Status: Sendable {
        /// The branch name; nil while HEAD is detached.
        var branch: String? = ""
        var head: String?
        var ahead = 0
        var behind = 0
        var changes: [FileChange] = []
    }

    private static let space = UInt8(ascii: " ")

    private let bytes: [UInt8]
    private var status = Status()

    private init(_ data: Data) { bytes = [UInt8](data) }

    static func parse(_ data: Data) -> Status {
        var parser = Self(data)
        parser.run()
        return parser.status
    }

    private mutating func run() {
        var start = 0
        while start < bytes.count {
            var end = recordEnd(from: start)
            if end - start >= 2, bytes[start + 1] == Self.space {
                end = consumeRecord(start, end)
            }
            start = end + 1
        }
    }

    private func recordEnd(from start: Int) -> Int {
        bytes[start...].firstIndex(of: GitOutput.nul) ?? bytes.count
    }

    /// Returns the end of the consumed records (a rename also consumes its original-path record).
    private mutating func consumeRecord(_ start: Int, _ end: Int) -> Int {
        switch bytes[start] {
        case UInt8(ascii: "?"):
            status.changes.append(FileChange(path: text(start + 2, end), indexStatus: "?", worktreeStatus: "?"))
        case UInt8(ascii: "1"): change(start, end, fields: 8)
        case UInt8(ascii: "u"): change(start, end, fields: 10)
        case UInt8(ascii: "2"): return rename(start, end)
        case UInt8(ascii: "#"): header(text(start, end))
        default: break
        }
        return end
    }

    /// Ordinary and unmerged entries: the path follows the `fields`-th space; XY is exactly two bytes.
    private mutating func change(_ start: Int, _ end: Int, fields: Int, original: String? = nil) {
        guard let pathStart = pathStart(start, end, fields: fields) else { return }
        status.changes.append(
            FileChange(
                path: text(pathStart, end), originalPath: original, indexStatus: Self.code(bytes[start + 2]),
                worktreeStatus: Self.code(bytes[start + 3])))
    }

    private mutating func rename(_ start: Int, _ end: Int) -> Int {
        guard pathStart(start, end, fields: 9) != nil, end < bytes.count else {
            change(start, end, fields: 9)
            return end
        }
        let next = recordEnd(from: end + 1)
        change(start, end, fields: 9, original: text(end + 1, next))
        return next
    }

    private func pathStart(_ start: Int, _ end: Int, fields: Int) -> Int? {
        guard end - start >= 5, bytes[start + 4] == Self.space, bytes[start + 2] != Self.space,
            bytes[start + 3] != Self.space
        else { return nil }
        var spaces = 0
        var index = start
        while index < end, spaces < fields {
            if bytes[index] == Self.space { spaces += 1 }
            index += 1
        }
        return spaces == fields ? index : nil
    }

    private mutating func header(_ record: String) {
        if let head = record.dropPrefix("# branch.oid ") {
            status.head = head == "(initial)" ? nil : head
        } else if let name = record.dropPrefix("# branch.head ") {
            status.branch = name == "(detached)" ? nil : name
        } else if let counts = record.dropPrefix("# branch.ab ") {
            let fields = counts.split(separator: " ")
            guard fields.count == 2 else { return }
            status.ahead = Int(fields[0].dropFirst()) ?? 0
            status.behind = Int(fields[1].dropFirst()) ?? 0
        }
    }

    private func text(_ from: Int, _ to: Int) -> String {
        String(decoding: bytes[from..<max(from, to)], as: UTF8.self)
    }

    /// Porcelain v2 writes "." for an unmodified side; the app shows a space.
    private static func code(_ byte: UInt8) -> String { byte == UInt8(ascii: ".") ? " " : String(UnicodeScalar(byte)) }
}

extension String {
    /// The rest of the string after `prefix`, or nil when it does not start with it.
    func dropPrefix(_ prefix: String) -> String? { hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil }
}
