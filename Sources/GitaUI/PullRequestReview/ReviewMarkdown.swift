import AppKit
import GitaCore

/// How review text reads in the window: GitHub's Markdown with its blocks (headings, bullet lists, fenced code, tables)
/// and inline styles (bold, code, links), the HTML bots write turned into the same (`ReviewHTML`), line breaks kept,
/// HTML comments (templates, bot markers) and link reference definitions removed, and "author · 2h ago" bylines.
@MainActor
enum ReviewMarkdown {
    /// The body without `<!-- … -->` blocks and surrounding blank lines.
    nonisolated static func visible(_ body: String) -> String {
        var text = body.replacingOccurrences(of: "\r\n", with: "\n")
        while let start = text.range(of: "<!--") {
            let end = text.range(of: "-->", range: start.upperBound..<text.endIndex)
            text.removeSubrange(start.lowerBound..<(end?.upperBound ?? text.endIndex))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One line's block: a heading (its level), a bullet, a line of fenced code, a table row (its cells), plain
    /// text, or a line that shows nothing (a fence, a table's delimiter row, a link reference definition).
    enum Block: Equatable {
        case heading(Int, String)
        case bullet(indent: String, String)
        case code(String)
        case row([String], header: Bool)
        case plain(String)
        case hidden
    }

    nonisolated static func isFence(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
    }

    /// Classifies each line; lines between fences are code, never Markdown. A table starts at a row whose next line
    /// is a delimiter row (`| --- | :-: |`) and runs while lines hold a `|`.
    nonisolated static func blocks(_ text: String) -> [Block] {
        let lines = text.components(separatedBy: "\n")
        var inFence = false
        var inTable = false
        var result: [Block] = []
        for (index, line) in lines.enumerated() {
            if isFence(line) {
                inFence.toggle()
                inTable = false
                result.append(.hidden)
            } else if inFence {
                result.append(.code(line))
            } else if inTable, line.contains("|") {
                let isDelimiter = result.last.map { if case .row(_, true) = $0 { true } else { false } } ?? false
                result.append(isDelimiter ? .hidden : .row(ReviewTable.cells(line), header: false))
            } else {
                let next = index + 1 < lines.count ? lines[index + 1] : ""
                inTable = line.contains("|") && ReviewTable.isDelimiter(next)
                result.append(inTable ? .row(ReviewTable.cells(line), header: true) : block(line))
            }
        }
        return result
    }

    private nonisolated static func block(_ line: String) -> Block {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if isDefinition(trimmed) { return .hidden }
        let hashes = trimmed.prefix { $0 == "#" }.count
        if (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " {
            return .heading(hashes, String(trimmed.dropFirst(hashes + 1)))
        }
        for marker in ["- ", "* ", "+ "] where trimmed.hasPrefix(marker) {
            let indent = String(line.prefix { $0 == " " || $0 == "\t" })
            return .bullet(indent: indent, String(trimmed.dropFirst(marker.count)))
        }
        return .plain(line)
    }

    /// `[label]: target`, which GitHub never shows (Vercel keeps its state in one).
    private nonisolated static func isDefinition(_ trimmed: String) -> Bool {
        guard trimmed.hasPrefix("["), !trimmed.hasPrefix("[^"), let close = trimmed.range(of: "]:") else {
            return false
        }
        let label = trimmed[trimmed.index(after: trimmed.startIndex)..<close.lowerBound]
        let target = trimmed[close.upperBound...].split(separator: " ", maxSplits: 1)
        guard !label.isEmpty, !label.contains("]"), let destination = target.first, !destination.isEmpty else {
            return false
        }
        // A destination alone, or with a quoted title: "[WIP]: fix things" is a sentence, not a definition.
        return target.count == 1 || ["\"", "'", "("].contains(target[1].trimmingCharacters(in: .whitespaces).prefix(1))
    }

    private struct AttributedCacheKey: Hashable {
        var body: String
        var fontSize: CGFloat
        var dark: Bool
        var theme: Theme.Choice
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.body == rhs.body && lhs.fontSize == rhs.fontSize && lhs.dark == rhs.dark && lhs.theme == rhs.theme
        }
        func hash(into hasher: inout Hasher) {
            hasher.combine(body)
            hasher.combine(fontSize)
            hasher.combine(dark)
            hasher.combine(theme)
        }
    }
    private static var attributedCache: [AttributedCacheKey: NSAttributedString] = [:]
    private static let attributedCacheLimit = 256

    static func attributed(_ body: String, font: NSFont = Theme.body) -> NSAttributedString {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let key = AttributedCacheKey(body: body, fontSize: font.pointSize, dark: dark, theme: Theme.current)
        if let cached = attributedCache[key] { return cached }
        let result = NSMutableAttributedString()
        var rows: [(cells: [String], header: Bool)] = []
        func line(_ text: NSAttributedString) {
            if result.length > 0 { result.append(NSAttributedString(string: "\n")) }
            result.append(text)
        }
        func flushTable() {
            if !rows.isEmpty { line(ReviewTable.attributed(rows, font: font)) }
            rows = []
        }
        for block in blocks(ReviewHTML.markdown(visible(body))) where block != .hidden {
            if case .row(let cells, let header) = block {
                rows.append((cells, header))
                continue
            }
            flushTable()
            line(attributed(block, font: font))
        }
        flushTable()
        if attributedCache.count >= attributedCacheLimit { attributedCache.removeAll(keepingCapacity: true) }
        attributedCache[key] = result
        return result
    }

    private static func attributed(_ block: Block, font: NSFont) -> NSAttributedString {
        switch block {
        case .heading(let level, let text):
            let size = font.pointSize + CGFloat(max(0, 4 - level))
            return inline(text, font: NSFontManager.shared.convert(font, toSize: size), bold: true)
        case .bullet(let indent, let text): return inline(indent + "•  " + text, font: font)
        case .code(let text):
            return NSAttributedString(string: text, attributes: [.font: Theme.mono, .foregroundColor: Theme.text])
        case .plain(let text): return inline(text, font: font)
        case .row(let cells, let header): return ReviewTable.attributed([(cells, header)], font: font)
        case .hidden: return NSAttributedString()
        }
    }

    /// One line's inline Markdown in `font` (bold throughout for a heading).
    static func inline(_ text: String, font: NSFont, bold: Bool = false) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let parsed =
            (try? NSMutableAttributedString(markdown: text, options: options, baseURL: nil))
            ?? NSMutableAttributedString(string: text)
        let whole = NSRange(location: 0, length: parsed.length)
        let base = bold ? styled(font, .stronglyEmphasized) : font
        parsed.addAttributes([.foregroundColor: Theme.text, .font: base], range: whole)
        parsed.enumerateAttribute(.inlinePresentationIntent, in: whole) { value, range, _ in
            guard let raw = value as? UInt else { return }
            parsed.addAttribute(.font, value: styled(base, InlinePresentationIntent(rawValue: raw)), range: range)
        }
        return parsed
    }

    /// Code in the code font; strong and emphasized text in bold and italic.
    static func styled(_ font: NSFont, _ intent: InlinePresentationIntent) -> NSFont {
        if intent.contains(.code) { return Theme.mono }
        var traits: NSFontDescriptor.SymbolicTraits = []
        if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
        if intent.contains(.emphasized) { traits.insert(.italic) }
        guard !traits.isEmpty else { return font }
        let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    /// A selectable, wrapping body label.
    static func bodyLabel(_ body: String) -> NSTextField {
        let label = Deck.wrapping("")
        label.attributedStringValue = attributed(body)
        label.isSelectable = true
        label.allowsEditingTextAttributes = true
        return label
    }

    /// "octocat · 2h ago".
    static func byline(_ author: String?, _ date: Date?) -> String {
        [author ?? String(localized: "Someone"), date.map { DeckFormat.relative($0) }].compactMap { $0 }.joined(
            separator: " · ")
    }

    static func verdict(_ kind: ConversationEntry.Kind) -> (text: String, symbol: String, color: NSColor) {
        switch kind {
        case .comment: (String(localized: "commented"), "text.bubble", Theme.secondaryText)
        case .review(.approved): (String(localized: "approved"), "checkmark.circle.fill", Theme.success)
        case .review(.changesRequested):
            (String(localized: "requested changes"), "exclamationmark.circle.fill", Theme.failure)
        case .review(.dismissed): (String(localized: "review dismissed"), "xmark.circle", Theme.idle)
        case .review: (String(localized: "reviewed"), "eye", Theme.secondaryText)
        }
    }
}
