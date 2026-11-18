import AppKit

/// A GitHub Markdown table in a review body: its rows split into cells, drawn as aligned columns (tab stops at each
/// column's widest cell), the header row in bold.
@MainActor
enum ReviewTable {
    private static let gap: CGFloat = 18

    /// `| --- | :-: |`: every cell dashes, with optional colons for alignment.
    nonisolated static func isDelimiter(_ line: String) -> Bool {
        guard line.contains("-") else { return false }
        let cells = cells(line)
        return !cells.isEmpty
            && cells.allSatisfy { cell in
                let dashes = cell.drop { $0 == ":" }.reversed().drop { $0 == ":" }
                return !dashes.isEmpty && dashes.allSatisfy { $0 == "-" }
            }
    }

    /// The cells between the pipes; a pipe escaped (`\|`) or inside code stays in its cell.
    nonisolated static func cells(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var inCode = false
        var escaped = false
        for character in line.trimmingCharacters(in: .whitespaces) {
            if character == "|", !inCode, !escaped {
                cells.append(current)
                current = ""
            } else {
                current.append(character)
            }
            if character == "`" { inCode.toggle() }
            escaped = character == "\\" && !escaped
        }
        cells.append(current)
        if cells.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeFirst() }
        if cells.count > 1, cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\|", with: "|") }
    }

    /// The rows as tab-separated lines that share one set of tab stops.
    static func attributed(_ rows: [(cells: [String], header: Bool)], font: NSFont) -> NSAttributedString {
        let rendered = rows.map { row in
            row.cells.map { ReviewMarkdown.inline($0, font: font, bold: row.header) }
        }
        var widths: [CGFloat] = []
        for row in rendered {
            for (column, cell) in row.enumerated() {
                let width = ceil(cell.size().width)
                if column < widths.count { widths[column] = max(widths[column], width) } else { widths.append(width) }
            }
        }
        var location: CGFloat = 0
        let style = NSMutableParagraphStyle()
        style.tabStops = widths.dropLast().map { width in
            location += width + gap
            return NSTextTab(textAlignment: .left, location: location)
        }
        style.paragraphSpacing = 2
        let result = NSMutableAttributedString()
        for (index, row) in rendered.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            for (column, cell) in row.enumerated() {
                if column > 0 { result.append(NSAttributedString(string: "\t", attributes: [.font: font])) }
                result.append(cell)
            }
        }
        result.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: result.length))
        return result
    }
}
