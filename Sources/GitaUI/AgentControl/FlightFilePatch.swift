import Foundation
import GitaCore

struct FlightFilePatch {
    let text: String
    let document: DiffDocument

    init(_ text: String) {
        self.text = text
        document = UnifiedDiff.parse(text)
    }

    /// Both Core queries use the same Git ordering and disable renames. Preserve exact patch bytes
    /// (including CRLF source lines) for the restore service's stale-diff check.
    static func sections(_ result: FlightDiffResult) -> [String: Substring] {
        let text = result.diffText
        let bytes = text.utf8
        var starts: [String.Index] = []
        var offset = bytes.startIndex
        while offset < bytes.endIndex {
            if bytes[offset...].starts(with: "diff --git ".utf8) { starts.append(offset) }
            guard let newline = bytes[offset...].firstIndex(of: 10) else { break }
            offset = bytes.index(after: newline)
        }
        let sections = zip(starts, starts.dropFirst() + [text.endIndex]).map { text[$0..<$1] }
        return Dictionary(zip(result.files, sections), uniquingKeysWith: { first, _ in first })
    }
}
