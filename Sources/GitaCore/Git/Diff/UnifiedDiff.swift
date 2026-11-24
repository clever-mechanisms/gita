public struct DiffLine: Sendable, Equatable {
    public var text: String
    public var old: String
    public var new: String
    public var kind: Character
    public var hunkIndex: Int?

    public init(text: String, old: String, new: String, kind: Character, hunkIndex: Int? = nil) {
        self.text = text
        self.old = old
        self.new = new
        self.kind = kind
        self.hunkIndex = hunkIndex
    }
}

public struct DiffHunk: Sendable {
    public var index: Int
    /// Empty when the document is ineligible for partial application.
    public var patch: String

    public init(index: Int, patch: String) {
        self.index = index
        self.patch = patch
    }
}

public struct DiffDocument: Sendable {
    public var lines: [DiffLine]
    public var hunks: [DiffHunk]
    public var canApplyHunks: Bool

    public init(lines: [DiffLine], hunks: [DiffHunk], canApplyHunks: Bool) {
        self.lines = lines
        self.hunks = hunks
        self.canApplyHunks = canApplyHunks
    }
}

/// Parses Git's unified diff without interpreting content as metadata. Application
/// is deliberately narrower than display: one regular file, unchanged mode and
/// path, complete ordinary hunks, and no other extended headers.
public enum UnifiedDiff {
    public static func parse(_ text: String) -> DiffDocument {
        var parser = Parser(text: text)
        return parser.parse()
    }

    struct HunkRange {
        let oldStart: Int
        let oldCount: Int
        let newStart: Int
        let newCount: Int

        // A zero-length range names the line before the insertion point.
        var oldAnchor: Int { oldStart + (oldCount == 0 ? 1 : 0) }
        var newAnchor: Int { newStart + (newCount == 0 ? 1 : 0) }
        var oldEnd: Int { oldAnchor + oldCount }
        var newEnd: Int { newAnchor + newCount }

        /// Hunks must be ordered, must not overlap, and must keep both sides in step between them.
        func continues(after previous: Self?) -> Bool {
            guard let previous else { return oldAnchor == newAnchor }
            guard oldAnchor >= previous.oldEnd, newAnchor >= previous.newEnd else { return false }
            return oldAnchor - previous.oldEnd == newAnchor - previous.newEnd
        }
    }

    static func parseHunkHeader(_ line: String) -> HunkRange? {
        Parser.parseRange(line)
    }

    private struct HunkState {
        let index: Int
        let textStart: String.Index
        let range: HunkRange?
        var oldSeen = 0
        var newSeen = 0
        var previousKind: Character?
        var noOldNewline = false
        var noNewNewline = false
        var changed = false
        var valid = true

        /// Numbers one `+`, `-` or context line; a line past the header's counts invalidates the hunk.
        mutating func take(_ kind: Character) -> (old: String, new: String) {
            var old = ""
            var new = ""
            if let range {
                if kind != "+" { old = takeOld(range) }
                if kind != "-" { new = takeNew(range) }
            }
            changed = changed || kind != " "
            previousKind = kind
            return (old, new)
        }

        /// `\ No newline at end of file` ends the side(s) of the previous line; anything else is not a hunk line.
        mutating func endMarker(_ line: String) {
            if line == "\\ No newline at end of file", let previous = previousKind, let range {
                if previous != "+" {
                    if oldSeen != range.oldCount { valid = false }
                    noOldNewline = true
                }
                if previous != "-" {
                    if newSeen != range.newCount { valid = false }
                    noNewNewline = true
                }
            } else {
                valid = false
            }
            previousKind = nil
        }

        private mutating func takeOld(_ range: HunkRange) -> String {
            guard oldSeen < range.oldCount && !noOldNewline else {
                valid = false
                return ""
            }
            defer { oldSeen += 1 }
            return String(range.oldStart + oldSeen)
        }

        private mutating func takeNew(_ range: HunkRange) -> String {
            guard newSeen < range.newCount && !noNewNewline else {
                valid = false
                return ""
            }
            defer { newSeen += 1 }
            return String(range.newStart + newSeen)
        }
    }

    private struct Parser {
        let text: String
        var lines: [DiffLine] = []
        var hunks: [DiffHunk] = []
        var hunkTextRanges: [Range<String.Index>] = []
        var headers: [String] = []
        var firstHunkStart: String.Index?
        var current: HunkState?
        var previousRange: HunkRange?
        var previousHadNoNewline = false
        var fileCount = 0
        var valid = true
        var bytesBeforeHunks = 0
        var byteCount = 0

        mutating func parse() -> DiffDocument {
            // Scan LF bytes, rather than Swift Characters: CRLF is a single
            // grapheme, and the CR belongs to a source line's exact patch data.
            let bytes = text.utf8
            var start = bytes.startIndex
            while start < bytes.endIndex {
                let end = bytes[start...].firstIndex(of: 10) ?? bytes.endIndex
                let terminated = end != bytes.endIndex
                let after = terminated ? bytes.index(after: end) : end
                let line = String(text[start..<end])
                let length = bytes.distance(from: start, to: after)
                byteCount += length
                if firstHunkStart == nil && !line.hasPrefix("@@") { bytesBeforeHunks += length }
                if !terminated || line.utf8.contains(0) { valid = false }
                consume(line, at: start)
                start = after
            }
            finishHunk(at: text.endIndex)

            var eligible = valid && fileCount == 1 && !hunks.isEmpty && validHeaders()
            // Every patch must repeat its file headers. Refuse a pathological
            // header/hunk ratio instead of creating quadratic-sized output.
            // A fixed allowance keeps ordinary long names and small hunks useful.
            let repeated = bytesBeforeHunks.multipliedReportingOverflow(by: max(0, hunks.count - 1))
            if repeated.overflow || repeated.partialValue > max(byteCount, 1_048_576) { eligible = false }
            if eligible, let firstHunkStart {
                let prefix = String(text[..<firstHunkStart])
                for index in hunks.indices {
                    hunks[index].patch = prefix + text[hunkTextRanges[index]]
                }
            }
            return DiffDocument(lines: lines, hunks: hunks, canApplyHunks: eligible)
        }

        mutating func consume(_ line: String, at start: String.Index) {
            if line.hasPrefix("diff ") {
                finishHunk(at: start)
                fileCount += 1
                if fileCount > 1 { valid = false }
                appendMetadata(line)
                return
            }
            if line.hasPrefix("@@") {
                startHunk(line, at: start)
                return
            }
            guard var hunk = current else {
                appendMetadata(line)
                return
            }
            let kind = line.first ?? "h"
            if kind == "+" || kind == "-" || kind == " " {
                let (old, new) = hunk.take(kind)
                lines.append(DiffLine(text: line, old: old, new: new, kind: kind, hunkIndex: hunk.index))
            } else {
                hunk.endMarker(line)
                lines.append(DiffLine(text: line, old: "", new: "", kind: "h", hunkIndex: hunk.index))
            }
            current = hunk
        }

        mutating func startHunk(_ line: String, at start: String.Index) {
            finishHunk(at: start)
            if previousHadNoNewline { valid = false }
            let range = Self.parseRange(line)
            if range?.continues(after: previousRange) != true { valid = false }
            if firstHunkStart == nil { firstHunkStart = start }
            current = HunkState(
                index: hunks.count, textStart: start, range: range)
            lines.append(DiffLine(text: line, old: "", new: "", kind: "@", hunkIndex: hunks.count))
        }

        mutating func appendMetadata(_ line: String) {
            if firstHunkStart == nil {
                // Four lines are the only supported header shape. Keep the
                // display, but do not retain unbounded duplicate metadata.
                if headers.count < 5 { headers.append(line) }
            } else {
                valid = false
            }
            lines.append(DiffLine(text: line, old: "", new: "", kind: "h"))
        }

        mutating func finishHunk(at end: String.Index) {
            guard let hunk = current else { return }
            if let range = hunk.range {
                if !hunk.valid || !hunk.changed || hunk.oldSeen != range.oldCount || hunk.newSeen != range.newCount {
                    valid = false
                }
                previousRange = range
            } else {
                valid = false
            }
            previousHadNoNewline = hunk.noOldNewline || hunk.noNewNewline
            hunks.append(DiffHunk(index: hunk.index, patch: ""))
            hunkTextRanges.append(hunk.textStart..<end)
            current = nil
        }

        func validHeaders() -> Bool {
            guard headers.count == 4,
                headers[0].hasPrefix("diff --git "),
                headers[1].hasPrefix("index "),
                let old = Self.path(headers[2], prefix: "--- a/", quotedPrefix: "--- \"a/"),
                let new = Self.path(headers[3], prefix: "+++ b/", quotedPrefix: "+++ \"b/"),
                old.bytes == new.bytes,
                headers[0].utf8.elementsEqual("diff --git \(old.token) \(new.token)".utf8)
            else { return false }
            let index = headers[1].dropFirst(6).split(separator: " ", omittingEmptySubsequences: false)
            guard index.count == 2, GitFileMode(rawValue: String(index[1]))?.isFile == true else { return false }
            let hashes = index[0].split(separator: ".", omittingEmptySubsequences: false)
            guard hashes.count == 3, hashes[1].isEmpty else { return false }
            return [hashes[0], hashes[2]].allSatisfy { hash in
                (4...64).contains(hash.utf8.count) && hash.utf8.contains(where: { $0 != 48 })
                    && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            }
        }

        static func path(_ line: String, prefix: String, quotedPrefix: String) -> (token: String, bytes: [UInt8])? {
            var token: String
            let path: [UInt8]
            if line.hasPrefix(quotedPrefix) {
                token = String(line.dropFirst(4))
                guard token.last == "\"" else { return nil }
                path = unquoted(Array(token.utf8.dropFirst(3).dropLast()))
            } else {
                guard line.hasPrefix(prefix) else { return nil }
                token = String(line.dropFirst(4))
                if token.last == "\t" { token.removeLast() }
                guard !token.utf8.contains(where: { $0 < 32 || $0 == 127 }) else { return nil }
                path = Array(token.utf8.dropFirst(2))
            }
            return isSafeRelativePath(path) ? (token, path) : nil
        }

        /// A relative path with no empty, `.`, `..` or `.git` component and no NUL.
        static func isSafeRelativePath(_ path: [UInt8]) -> Bool {
            guard !path.isEmpty, !path.contains(0), path.first != 47 else { return false }
            let components = path.split(separator: 47, omittingEmptySubsequences: false)
            return components.allSatisfy { !$0.isEmpty && $0 != [46] && $0 != [46, 46] && $0 != [46, 103, 105, 116] }
        }

        /// Git's C-style quoted path body: backslash escapes and three-digit octal bytes; empty (never a valid
        /// path) on anything malformed.
        static func unquoted(_ encoded: [UInt8]) -> [UInt8] {
            var path: [UInt8] = []
            var index = 0
            while index < encoded.count {
                let byte = encoded[index]
                index += 1
                guard byte == 92 else {
                    guard byte != 34, byte >= 32 else { return [] }
                    path.append(byte)
                    continue
                }
                guard index < encoded.count else { return [] }
                let escaped = encoded[index]
                index += 1
                if let simple = simpleEscapes[escaped] {
                    path.append(simple)
                } else if (48...51).contains(escaped), index + 1 < encoded.count,
                    (48...55).contains(encoded[index]), (48...55).contains(encoded[index + 1])
                {
                    path.append((escaped - 48) * 64 + (encoded[index] - 48) * 8 + (encoded[index + 1] - 48))
                    index += 2
                } else {
                    return []
                }
            }
            return path
        }

        /// `\a \b \t \n \v \f \r \" \\` and the byte each stands for.
        private static let simpleEscapes: [UInt8: UInt8] = [
            97: 7, 98: 8, 116: 9, 110: 10, 118: 11, 102: 12, 114: 13, 34: 34, 92: 92,
        ]

        static func parseRange(_ line: String) -> HunkRange? {
            let bytes = Array(line.utf8)
            var cursor = 0
            func take(_ expected: [UInt8]) -> Bool {
                guard bytes.count - cursor >= expected.count,
                    bytes[cursor..<(cursor + expected.count)].elementsEqual(expected)
                else { return false }
                cursor += expected.count
                return true
            }
            func number() -> Int? {
                let start = cursor
                var value = 0
                while cursor < bytes.count, (48...57).contains(bytes[cursor]) {
                    let product = value.multipliedReportingOverflow(by: 10)
                    let sum = product.partialValue.addingReportingOverflow(Int(bytes[cursor] - 48))
                    guard !product.overflow, !sum.overflow else { return nil }
                    value = sum.partialValue
                    cursor += 1
                }
                return cursor > start ? value : nil
            }
            func count() -> Int? {
                if cursor < bytes.count, bytes[cursor] == 44 {
                    cursor += 1
                    return number()
                }
                return 1
            }
            guard take([64, 64, 32, 45]), let oldStart = number(), let oldCount = count(),
                take([32, 43]), let newStart = number(), let newCount = count(), take([32, 64, 64]),
                cursor == bytes.count || bytes[cursor] == 32,
                oldStart > 0 || oldCount == 0, newStart > 0 || newCount == 0,
                !oldStart.addingReportingOverflow(max(1, oldCount)).overflow,
                !newStart.addingReportingOverflow(max(1, newCount)).overflow
            else { return nil }
            return HunkRange(oldStart: oldStart, oldCount: oldCount, newStart: newStart, newCount: newCount)
        }
    }
}
