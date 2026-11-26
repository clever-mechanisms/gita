import Foundation

enum CollisionRadarDiffParser {
    struct Change {
        var isNew = false
        var hunks: [BaseHunk] = []
    }

    /// An insertion is in the gap after its base line. It intersects a replacement
    /// spanning that gap, but does not intersect a replacement ending on that line.
    struct BaseHunk {
        let range: ClosedRange<Int>
        let insertion: Bool
        var start: (Int, LinePosition) { (range.lowerBound, insertion ? .after : .line) }
        var end: (Int, LinePosition) { (range.upperBound, insertion ? .after : .line) }
    }

    enum LinePosition: Int, Comparable {
        case line, after
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// With --no-renames, the NUL-delimited raw records identify one path per patch,
    /// including binary files, tabs, newlines, mode changes, and empty added files.
    static func changes(_ data: Data) -> [String: Change] {
        guard let boundary = data.range(of: Data([0, 0])) else { return [:] }
        let fields = GitOutput.nulFields(data[..<boundary.lowerBound])
        var paths: [String] = []
        var result: [String: Change] = [:]
        for i in stride(from: 0, to: fields.count - 1, by: 2) {
            paths.append(fields[i + 1])
            result[fields[i + 1]] = Change(isNew: fields[i].hasSuffix(" A"))
        }
        var file = -1
        var header: Data.SubSequence?
        for bytes in data[boundary.upperBound...].split(separator: 10) {
            if bytes.starts(with: "diff --git ".utf8) {
                // A type change can emit a deletion and an addition for the same raw record.
                if bytes != header { file += 1 }
                header = bytes
            } else if bytes.starts(with: "@@ ".utf8), paths.indices.contains(file),
                let hunk = UnifiedDiff.parseHunkHeader(String(decoding: bytes, as: UTF8.self))
            {
                let range = hunk.oldStart...(hunk.oldStart + max(0, hunk.oldCount - 1))
                result[paths[file]]?.hunks.append(BaseHunk(range: range, insertion: hunk.oldCount == 0))
            }
        }
        return result
    }

    static func classify(_ lhs: Change, _ rhs: Change, conflict: Bool) -> (CollisionSeverity, [LineRangeOverlap]) {
        if lhs.isNew && rhs.isNew { return (conflict ? .high : .medium, []) }
        var severity: CollisionSeverity = conflict ? .high : .low
        var overlaps: [LineRangeOverlap] = []
        var i = 0
        var j = 0
        while i < lhs.hunks.count && j < rhs.hunks.count {
            let a = lhs.hunks[i]
            let b = rhs.hunks[j]
            let start = max(a.range.lowerBound, b.range.lowerBound)
            let end = min(a.range.upperBound, b.range.upperBound)
            if a.start <= b.end && b.start <= a.end {
                overlaps.append(
                    LineRangeOverlap(
                        sourceStart: a.range.lowerBound, sourceEnd: a.range.upperBound,
                        targetStart: b.range.lowerBound, targetEnd: b.range.upperBound, overlapStart: start,
                        overlapEnd: end))
                severity = .high
            } else if start - end <= 15 {
                severity = max(severity, .medium)
            }
            if a.end <= b.end { i += 1 }
            if b.end <= a.end { j += 1 }
        }
        return (severity, overlaps)
    }

    struct Merge {
        var tree: String?
        var paths: Set<String> = []
        var messages: [String] = []
        var conflict = false
    }

    /// -z emits tree, paths, empty field, then repeated path-count/paths/type/message records.
    static func merge(_ result: CommandResult) throws -> Merge {
        let fields = GitOutput.nulFields(result.stdout)
        guard let tree = fields.first, GitParsers.isObjectID(tree),
            let end = fields.dropFirst().firstIndex(of: "")
        else { throw GitError.invalidReference }
        var merge = Merge(tree: tree, paths: Set(fields[1..<end]), conflict: result.exitCode == 1)
        var i = end + 1
        while i < fields.count, !fields[i].isEmpty {
            guard let count = Int(fields[i]), count >= 0, count <= fields.count - i - 3 else {
                throw GitError.commandFailed("Invalid merge-tree message")
            }
            merge.messages.append(GitOutput.withoutTerminalLF(fields[i + count + 2]))
            i += count + 3
        }
        return merge
    }
}
