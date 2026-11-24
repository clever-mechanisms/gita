import CoreGraphics
import Foundation
import GitaCore

/// Turns what the diff pane shows into rows: a unified diff, or a file's contents (a blob) numbered line by line.
enum DiffDocumentBuilder {
    /// The rows, longest line (in UTF-16 units), intra-line word diff ranges, syntax tokens, and split-view rows.
    struct Result: Sendable {
        var document: DiffDocument
        var longestLine: Int
        var wordHighlights: [[Range<Int>]]
        var syntaxTokens: [[SyntaxToken]]
        var splitRows: [SplitDiffRow]
        var isBlob: Bool
    }

    /// Approximate width of one monospaced character at 11 pt and the room beside the text (gutter and margin).
    private static let characterWidth: CGFloat = 7
    private static let baseFontSize: CGFloat = 11
    private static let gutterWidth: CGFloat = 120
    /// AppKit's table column stays below this width.
    private static let maximumColumnWidth: CGFloat = 24_000
    /// Very long single lines (e.g. minified files) skip word-level diffing to keep parsing responsive.
    private static let maxWordDiffLineLength = 2_000

    static func build(_ text: String, blob: Bool, path: String? = nil) -> Result {
        let document = blob ? self.blob(text) : UnifiedDiff.parse(text)
        let longest = document.lines.reduce(0) { max($0, $1.text.utf16.count) }
        let highlights =
            blob
            ? Array(repeating: [Range<Int>](), count: document.lines.count)
            : wordHighlights(for: document.lines)
        let tokens = SyntaxTokenizer.tokenize(lines: document.lines, path: path, isBlob: blob)
        let splitRows = DiffSplitPresenter.rows(
            lines: document.lines, wordHighlights: highlights, syntaxTokens: tokens)
        return Result(
            document: document, longestLine: longest, wordHighlights: highlights,
            syntaxTokens: tokens, splitRows: splitRows, isBlob: blob)
    }

    /// A file's lines, numbered on the new side; no hunks, so nothing can be staged from it.
    static func blob(_ text: String) -> DiffDocument {
        let lines = text.components(separatedBy: "\n").enumerated().map {
            DiffLine(text: $0.element, old: "", new: String($0.offset + 1), kind: " ", hunkIndex: nil)
        }
        return DiffDocument(lines: lines, hunks: [], canApplyHunks: false)
    }

    /// Computes intra-line changed word ranges (UTF-16 offsets into each `DiffLine.text`) by pairing the k-th removed
    /// line with the k-th added line when contiguous run lengths are within 2x of each other.
    static func wordHighlights(for lines: [DiffLine]) -> [[Range<Int>]] {
        var highlights = Array(repeating: [Range<Int>](), count: lines.count)
        var index = 0
        while index < lines.count {
            guard lines[index].kind == "-" else {
                index += 1
                continue
            }
            let removedStart = index
            while index < lines.count, lines[index].kind == "-" { index += 1 }
            let addedStart = index
            while index < lines.count, lines[index].kind == "+" { index += 1 }
            pairWordHighlights(
                removed: Array(removedStart..<addedStart), added: Array(addedStart..<index), lines: lines,
                into: &highlights)
        }
        return highlights
    }

    private static func pairWordHighlights(
        removed: [Int], added: [Int], lines: [DiffLine], into highlights: inout [[Range<Int>]]
    ) {
        guard !removed.isEmpty, !added.isEmpty,
            removed.count <= added.count * 2, added.count <= removed.count * 2
        else { return }
        for pair in 0..<min(removed.count, added.count) {
            let remRow = removed[pair]
            let addRow = added[pair]
            let remText = lines[remRow].text
            let addText = lines[addRow].text
            guard remText.utf16.count <= maxWordDiffLineLength,
                addText.utf16.count <= maxWordDiffLineLength,
                !remText.isEmpty, !addText.isEmpty
            else { continue }
            let remBody = String(remText.dropFirst())
            let addBody = String(addText.dropFirst())
            highlights[remRow] = MergeText.changedWords(in: remBody, comparedTo: addBody).map {
                ($0.lowerBound + 1)..<($0.upperBound + 1)
            }
            highlights[addRow] = MergeText.changedWords(in: addBody, comparedTo: remBody).map {
                ($0.lowerBound + 1)..<($0.upperBound + 1)
            }
        }
    }

    /// The code column's width: the pane's width, or wide enough for the longest line.
    static func columnWidth(longestLine: Int, minimum: CGFloat, fontSize: CGFloat = 11) -> CGFloat {
        let scaledCharWidth = characterWidth * (fontSize / baseFontSize)
        return max(minimum, min(maximumColumnWidth, CGFloat(longestLine) * scaledCharWidth + gutterWidth))
    }

    static func cleanCodeText(lines: [DiffLine], rows: IndexSet, isBlob: Bool) -> String {
        let picked = rows.sorted().compactMap { lines.indices.contains($0) ? lines[$0] : nil }
        guard !picked.isEmpty else { return "" }
        if isBlob { return picked.map(\.text).joined(separator: "\n") }
        let codeLines = picked.filter {
            $0.kind == "+" || $0.kind == "-" || ($0.kind == " " && $0.hunkIndex != nil)
        }
        if !codeLines.isEmpty { return codeLines.map { String($0.text.dropFirst()) }.joined(separator: "\n") }
        return picked.map(\.text).joined(separator: "\n")
    }

    static func patchText(document: DiffDocument?, lines: [DiffLine], rows: IndexSet) -> String {
        let picked = rows.sorted().compactMap { lines.indices.contains($0) ? lines[$0] : nil }
        guard !picked.isEmpty else { return "" }
        let hunkIndices = Set(picked.compactMap(\.hunkIndex))
        if hunkIndices.count == 1, let index = hunkIndices.first,
            let hunk = document?.hunks.first(where: { $0.index == index }), !hunk.patch.isEmpty
        {
            let hunkLineCount = lines.count { $0.hunkIndex == index }
            if picked.count == 1 || picked.contains(where: { $0.kind == "@" }) || picked.count >= hunkLineCount {
                return hunk.patch
            }
        }
        return picked.map(\.text).joined(separator: "\n")
    }

    static func sourceLineNumber(for line: DiffLine) -> Int? {
        if let new = Int(line.new) { return new }
        if let old = Int(line.old) { return old }
        guard line.kind == "@", line.text.hasPrefix("@@ ") else { return nil }
        let parts = line.text.dropFirst(3).split(separator: " ")
        guard parts.count >= 2, parts[1].hasPrefix("+") else { return nil }
        let startToken = parts[1].dropFirst().split(separator: ",").first
        return startToken.flatMap { Int($0) }
    }

    static func changedLineCount(in lines: [DiffLine], hunkIndex: Int) -> Int {
        lines.count { $0.hunkIndex == hunkIndex && ($0.kind == "+" || $0.kind == "-") }
    }
}
