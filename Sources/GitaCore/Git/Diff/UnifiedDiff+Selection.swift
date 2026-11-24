import Foundation

/// Partial-patch construction for line-level staging, unstaging, and working-tree discard.
extension UnifiedDiff {
    public struct Hunk: Sendable, Equatable {
        public enum Mode: Sendable, Equatable {
            case stage
            case unstage
            case discard
        }

        public struct Line: Sendable, Equatable {
            public var kind: Character
            public var rawText: String
            public var noNewline: Bool

            public init(kind: Character, rawText: String, noNewline: Bool = false) {
                self.kind = kind
                self.rawText = rawText
                self.noNewline = noNewline
            }
        }

        public let filePrefix: String
        public let oldStart: Int
        public let oldCount: Int
        public let newStart: Int
        public let newCount: Int
        public let headerSuffix: String
        public let lines: [Line]

        public init?(patch: String) {
            let split = Self.splitLines(patch)
            guard let headerIndex = split.firstIndex(where: { $0.hasPrefix("@@") }),
                let range = UnifiedDiff.parseHunkHeader(split[headerIndex])
            else { return nil }
            let headerLine = split[headerIndex]
            let prefix = split[..<headerIndex].map { $0 + "\n" }.joined()
            guard !prefix.isEmpty else { return nil }
            let suffix = Self.extractHeaderSuffix(headerLine)
            let parsedLines = Self.parseBodyLines(split[(headerIndex + 1)...])
            guard !parsedLines.isEmpty else { return nil }
            self.filePrefix = prefix
            self.oldStart = range.oldStart
            self.oldCount = range.oldCount
            self.newStart = range.newStart
            self.newCount = range.newCount
            self.headerSuffix = suffix
            self.lines = parsedLines
        }

        /// Builds a valid unified-diff patch containing only the selected body lines (`0..<lines.count`).
        /// Returns `nil` when no `+` or `−` line is selected or the selection cannot form a valid patch.
        public func patch(selecting selectedIndices: Set<Int>, mode: Mode) -> String? {
            guard let body = patchBody(selecting: selectedIndices, mode: mode, shift: 0) else { return nil }
            return filePrefix + body.text
        }

        fileprivate func patchBody(
            selecting selectedIndices: Set<Int>, mode: Mode, shift: Int
        ) -> (text: String, delta: Int)? {
            let filtered = filterLines(selecting: selectedIndices, mode: mode)
            guard !filtered.isEmpty else { return nil }
            let oldTotal = filtered.count { $0.kind == " " || $0.kind == "-" }
            let newTotal = filtered.count { $0.kind == " " || $0.kind == "+" }
            let delta = newTotal - oldTotal
            let starts = recomputedStarts(mode: mode, oldTotal: oldTotal, newTotal: newTotal, shift: shift)
            var result = "@@ -\(starts.old),\(oldTotal) +\(starts.new),\(newTotal) @@\(headerSuffix)\n"
            for line in filtered {
                result += line.rawText + "\n"
                if line.noNewline { result += "\\ No newline at end of file\n" }
            }
            return (result, delta)
        }

        private func filterLines(selecting selectedIndices: Set<Int>, mode: Mode) -> [Line] {
            var output: [Line] = []
            var hasChange = false
            for (index, line) in lines.enumerated() {
                let selected = selectedIndices.contains(index)
                switch line.kind {
                case " ":
                    output.append(line)
                case "-":
                    if selected {
                        hasChange = true
                        output.append(line)
                    } else if mode == .stage {
                        output.append(
                            Line(kind: " ", rawText: " " + line.rawText.dropFirst(), noNewline: line.noNewline))
                    }
                case "+":
                    if selected {
                        hasChange = true
                        output.append(line)
                    } else if mode != .stage {
                        output.append(
                            Line(kind: " ", rawText: " " + line.rawText.dropFirst(), noNewline: line.noNewline))
                    }
                default:
                    return []
                }
            }
            guard hasChange, Self.hasValidNoNewlinePlacement(in: output) else { return [] }
            return output
        }

        private func recomputedStarts(mode: Mode, oldTotal: Int, newTotal: Int, shift: Int) -> (old: Int, new: Int) {
            if mode == .stage {
                let adjustedNew = max(0, newStart + shift)
                let outOld = oldTotal == 0 ? max(0, oldStart) : max(1, oldStart)
                let outNew = newTotal == 0 ? adjustedNew : max(1, adjustedNew)
                return (outOld, outNew)
            }
            let adjustedOld = max(0, oldStart - shift)
            let outOld = oldTotal == 0 ? adjustedOld : max(1, adjustedOld)
            let outNew = newTotal == 0 ? max(0, newStart) : max(1, newStart)
            return (outOld, outNew)
        }

        private static func hasValidNoNewlinePlacement(in lines: [Line]) -> Bool {
            for index in lines.indices where lines[index].noNewline {
                let line = lines[index]
                let isLast = index == lines.count - 1
                if isLast { continue }
                // A `-` line with no newline can be followed by `+` lines; a context line with no newline cannot sit
                // before another line in the resulting file.
                if line.kind == "-" && lines[index + 1].kind == "+" { continue }
                return false
            }
            return true
        }

        private static func splitLines(_ patch: String) -> [String] {
            var result: [String] = []
            let bytes = patch.utf8
            var start = bytes.startIndex
            while start < bytes.endIndex {
                let end = bytes[start...].firstIndex(of: 10) ?? bytes.endIndex
                result.append(String(patch[start..<end]))
                start = end < bytes.endIndex ? bytes.index(after: end) : end
            }
            return result
        }

        private static func extractHeaderSuffix(_ headerLine: String) -> String {
            guard headerLine.hasPrefix("@@ ") else { return "" }
            let rest = headerLine.dropFirst(3)
            guard let closing = rest.range(of: " @@") else { return "" }
            return String(rest[closing.upperBound...])
        }

        private static func parseBodyLines(_ rawLines: ArraySlice<String>) -> [Line] {
            var parsed: [Line] = []
            for raw in rawLines {
                if raw == "\\ No newline at end of file" {
                    guard !parsed.isEmpty else { return [] }
                    parsed[parsed.count - 1].noNewline = true
                    continue
                }
                guard let kind = raw.first, kind == " " || kind == "-" || kind == "+" else { return [] }
                parsed.append(Line(kind: kind, rawText: raw, noNewline: false))
            }
            return parsed
        }
    }

    /// Builds a combined partial patch across one or more hunks from `DiffDocument` row indices.
    public static func patch(document: DiffDocument, selecting selectedRows: IndexSet, mode: Hunk.Mode) -> String? {
        guard document.canApplyHunks, !document.hunks.isEmpty else { return nil }
        let selectionByHunk = groupSelectedBodyIndices(document: document, selectedRows: selectedRows)
        guard !selectionByHunk.isEmpty else { return nil }
        if document.hunks.count == 1, let only = document.hunks.first,
            let selected = selectionByHunk[only.index], let hunk = Hunk(patch: only.patch)
        {
            return hunk.patch(selecting: selected, mode: mode)
        }

        var prefix = ""
        var bodies: [String] = []
        var origCumulativeDelta = 0
        var partialCumulativeDelta = 0
        for hunkInfo in document.hunks {
            guard let hunk = Hunk(patch: hunkInfo.patch) else { continue }
            let origDelta = hunk.newCount - hunk.oldCount
            defer { origCumulativeDelta += origDelta }
            guard let selected = selectionByHunk[hunkInfo.index], !selected.isEmpty else { continue }
            let shift = partialCumulativeDelta - origCumulativeDelta
            guard let body = hunk.patchBody(selecting: selected, mode: mode, shift: shift) else { continue }
            if prefix.isEmpty { prefix = hunk.filePrefix }
            bodies.append(body.text)
            partialCumulativeDelta += body.delta
        }
        guard !prefix.isEmpty, !bodies.isEmpty else { return nil }
        return prefix + bodies.joined()
    }

    private static func groupSelectedBodyIndices(document: DiffDocument, selectedRows: IndexSet) -> [Int: Set<Int>] {
        var localIndexByHunk: [Int: Int] = [:]
        var result: [Int: Set<Int>] = [:]
        for (row, line) in document.lines.enumerated() {
            guard let hunkIndex = line.hunkIndex else { continue }
            guard line.kind == " " || line.kind == "-" || line.kind == "+" else { continue }
            let localIndex = localIndexByHunk[hunkIndex, default: 0]
            localIndexByHunk[hunkIndex] = localIndex + 1
            if selectedRows.contains(row), line.kind == "+" || line.kind == "-" {
                result[hunkIndex, default: []].insert(localIndex)
            }
        }
        return result
    }
}
