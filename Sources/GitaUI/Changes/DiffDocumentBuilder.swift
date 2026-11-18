import CoreGraphics
import GitaCore

/// Turns what the diff pane shows into rows: a unified diff, or a file's contents (a blob) numbered line by line.
enum DiffDocumentBuilder {
    /// The rows and the length of the longest line (in UTF-16 units, which sizes the column).
    struct Result: Sendable {
        var document: DiffDocument
        var longestLine: Int
    }
    /// Approximate width of one monospaced character and the room beside the text (gutter and margin).
    private static let characterWidth: CGFloat = 7
    private static let gutterWidth: CGFloat = 120
    /// AppKit's table column stays below this width.
    private static let maximumColumnWidth: CGFloat = 24_000

    static func build(_ text: String, blob: Bool) -> Result {
        let document = blob ? self.blob(text) : UnifiedDiff.parse(text)
        let longest = document.lines.reduce(0) { max($0, $1.text.utf16.count) }
        return Result(document: document, longestLine: longest)
    }

    /// A file's lines, numbered on the new side; no hunks, so nothing can be staged from it.
    static func blob(_ text: String) -> DiffDocument {
        let lines = text.components(separatedBy: "\n").enumerated().map {
            DiffLine(text: $0.element, old: "", new: String($0.offset + 1), kind: " ", hunkIndex: nil)
        }
        return DiffDocument(lines: lines, hunks: [], canApplyHunks: false)
    }

    /// The code column's width: the pane's width, or wide enough for the longest line.
    static func columnWidth(longestLine: Int, minimum: CGFloat) -> CGFloat {
        max(minimum, min(maximumColumnWidth, CGFloat(longestLine) * characterWidth + gutterWidth))
    }
}
