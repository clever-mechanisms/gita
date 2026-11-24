import AppKit
import GitaCore

enum SyntaxTokenKind: Sendable, Equatable {
    case keyword
    case string
    case comment
    case number
    case type
    case preprocessor
    case heading
    case property

    @MainActor
    var color: NSColor {
        switch self {
        case .keyword: Theme.dynamic(0xAD3DA4, 0xFC5FA3)
        case .string: Theme.dynamic(0xC41A16, 0xFC6A5D)
        case .comment: Theme.dynamic(0x5D6C79, 0x7F8C98)
        case .number: Theme.dynamic(0x1C00CF, 0xD0BF69)
        case .type: Theme.dynamic(0x3F6E74, 0x9EF1DD)
        case .preprocessor: Theme.dynamic(0x643820, 0xFD8F3F)
        case .heading: Theme.dynamic(0x0F68A0, 0x67B7A4)
        case .property: Theme.dynamic(0x326D74, 0x67B7A4)
        }
    }
}

struct SyntaxToken: Sendable, Equatable {
    var range: Range<Int>
    var kind: SyntaxTokenKind
}

/// Zero-dependency, line-oriented lexer carrying block-comment and multi-line string state across lines.
struct SyntaxTokenizer: Sendable {
    static let maxLineLength = 2_000
    static let maxDocumentLines = 50_000

    enum CarriedState: Sendable, Equatable {
        case none
        case blockComment
        case tripleDoubleQuote
        case tripleSingleQuote
        case backtick
    }

    var state: CarriedState = .none

    /// Tokenizes parsed `DiffLine` rows for a file path, keeping separate lexer states for removed (`-`) and
    /// added/context (`+` / ` `) streams so a block comment on one side never bleeds into the other.
    static func tokenize(lines: [DiffLine], path: String?, isBlob: Bool) -> [[SyntaxToken]] {
        guard lines.count <= maxDocumentLines, let language = SyntaxLanguage(path: path) else {
            return Array(repeating: [], count: lines.count)
        }
        if isBlob {
            return tokenize(codeLines: lines.map(\.text), language: language)
        }
        var oldTokenizer = Self()
        var newTokenizer = Self()
        var result: [[SyntaxToken]] = []
        result.reserveCapacity(lines.count)
        for line in lines {
            if line.kind == "@" || line.kind == "h" {
                oldTokenizer.state = .none
                newTokenizer.state = .none
                result.append([])
                continue
            }
            let hasPrefix = line.kind == "+" || line.kind == "-" || line.kind == " "
            let code = hasPrefix ? String(line.text.dropFirst()) : line.text
            let offset = hasPrefix ? 1 : 0
            let tokens: [SyntaxToken]
            switch line.kind {
            case "-":
                tokens = oldTokenizer.tokenizeLine(code, language: language)
            case "+":
                tokens = newTokenizer.tokenizeLine(code, language: language)
            default:
                tokens = newTokenizer.tokenizeLine(code, language: language)
                oldTokenizer.state = newTokenizer.state
            }
            if offset == 0 {
                result.append(tokens)
            } else {
                result.append(
                    tokens.map {
                        SyntaxToken(range: ($0.range.lowerBound + 1)..<($0.range.upperBound + 1), kind: $0.kind)
                    })
            }
        }
        return result
    }

    /// Tokenizes plain source lines (useful for `ReviewDiffView` and non-diff views).
    static func tokenize(codeLines: [String], language: SyntaxLanguage) -> [[SyntaxToken]] {
        guard codeLines.count <= maxDocumentLines else { return Array(repeating: [], count: codeLines.count) }
        var tokenizer = Self()
        return codeLines.map { tokenizer.tokenizeLine($0, language: language) }
    }

    mutating func tokenizeLine(_ line: String, language: SyntaxLanguage) -> [SyntaxToken] {
        let units = Array(line.utf16)
        guard !units.isEmpty, units.count <= Self.maxLineLength else { return [] }
        let spec = language.spec
        switch spec.family {
        case .cLike, .python, .shell:
            return tokenizeCode(units, spec: spec)
        case .json:
            return tokenizeJSON(units)
        case .yaml:
            return tokenizeYAML(units, spec: spec)
        case .toml:
            return tokenizeTOML(units, spec: spec)
        case .markdown:
            return tokenizeMarkdown(units)
        }
    }

    private mutating func tokenizeCode(_ units: [UInt16], spec: SyntaxLanguageSpec) -> [SyntaxToken] {
        var tokens: [SyntaxToken] = []
        var cursor = 0
        if state != .none {
            guard let continued = consumeCarried(units, from: &cursor, spec: spec) else {
                return [SyntaxToken(range: 0..<units.count, kind: state == .blockComment ? .comment : .string)]
            }
            tokens.append(continued)
        }
        while cursor < units.count {
            let ch = units[cursor]
            if isWhitespace(ch) {
                cursor += 1
            } else if let comment = scanCommentIfAny(units, from: &cursor, spec: spec) {
                tokens.append(comment)
            } else if let string = scanStringIfAny(units, from: &cursor, spec: spec) {
                tokens.append(string)
            } else if let special = scanDirectiveOrMarkdown(units, from: &cursor, spec: spec) {
                tokens.append(special)
            } else if isDigit(ch) {
                tokens.append(scanNumber(units, from: &cursor))
            } else if isIdentStart(ch) {
                if let ident = scanIdentifier(units, from: &cursor, spec: spec) { tokens.append(ident) }
            } else {
                cursor += 1
            }
        }
        return tokens
    }

    private mutating func consumeCarried(
        _ units: [UInt16], from cursor: inout Int, spec: SyntaxLanguageSpec
    ) -> SyntaxToken? {
        switch state {
        case .blockComment:
            if let end = findTwoChar(units, from: cursor, first: 42, second: 47) {
                state = .none
                cursor = end
                return SyntaxToken(range: 0..<end, kind: .comment)
            }
            return nil
        case .tripleDoubleQuote:
            return scanTripleEnd(units, from: &cursor, quote: 34)
        case .tripleSingleQuote:
            return scanTripleEnd(units, from: &cursor, quote: 39)
        case .backtick where spec.supportsBacktickStrings:
            return scanSingleDelimiterEnd(units, from: &cursor, delimiter: 96, clearsState: true)
        default:
            state = .none
            return nil
        }
    }

    private mutating func scanCommentIfAny(
        _ units: [UInt16], from cursor: inout Int, spec: SyntaxLanguageSpec
    ) -> SyntaxToken? {
        let ch = units[cursor]
        if spec.family == .cLike, ch == 47, cursor + 1 < units.count {
            if units[cursor + 1] == 47 {
                let start = cursor
                cursor = units.count
                return SyntaxToken(range: start..<units.count, kind: .comment)
            }
            if units[cursor + 1] == 42 {
                let start = cursor
                cursor += 2
                if let end = findTwoChar(units, from: cursor, first: 42, second: 47) {
                    cursor = end
                    return SyntaxToken(range: start..<end, kind: .comment)
                }
                cursor = units.count
                state = .blockComment
                return SyntaxToken(range: start..<units.count, kind: .comment)
            }
        }
        if (spec.family == .python || spec.family == .shell) && ch == 35 {
            let start = cursor
            cursor = units.count
            return SyntaxToken(range: start..<units.count, kind: .comment)
        }
        return nil
    }

    mutating func scanStringIfAny(
        _ units: [UInt16], from cursor: inout Int, spec: SyntaxLanguageSpec
    ) -> SyntaxToken? {
        let ch = units[cursor]
        if spec.supportsTripleQuotes, ch == 34 || ch == 39, hasTriple(units, at: cursor, quote: ch) {
            let start = cursor
            cursor += 3
            state = ch == 34 ? .tripleDoubleQuote : .tripleSingleQuote
            if let closed = scanTripleEnd(units, from: &cursor, quote: ch) {
                return SyntaxToken(range: start..<closed.range.upperBound, kind: .string)
            }
            return SyntaxToken(range: start..<units.count, kind: .string)
        }
        if ch == 34 || ch == 39 {
            return scanQuoted(units, from: &cursor, quote: ch, escape: spec.family != .toml || ch == 34)
        }
        if spec.supportsBacktickStrings && ch == 96 {
            let start = cursor
            cursor += 1
            state = .backtick
            if let closed = scanSingleDelimiterEnd(units, from: &cursor, delimiter: 96, clearsState: true) {
                return SyntaxToken(range: start..<closed.range.upperBound, kind: .string)
            }
            return SyntaxToken(range: start..<units.count, kind: .string)
        }
        return nil
    }

    private func scanDirectiveOrMarkdown(
        _ units: [UInt16], from cursor: inout Int, spec: SyntaxLanguageSpec
    ) -> SyntaxToken? {
        let ch = units[cursor]
        if spec.supportsPreprocessor && ch == 35 && isLineLeading(units, before: cursor) {
            let start = cursor
            cursor += 1
            while cursor < units.count, isIdentCont(units[cursor]) { cursor += 1 }
            return SyntaxToken(range: start..<cursor, kind: .preprocessor)
        }
        if spec.supportsAtKeyword && ch == 64 {
            let start = cursor
            cursor += 1
            while cursor < units.count, isIdentCont(units[cursor]) { cursor += 1 }
            return cursor > start + 1 ? SyntaxToken(range: start..<cursor, kind: .keyword) : nil
        }
        return nil
    }

    mutating func scanTripleEnd(_ units: [UInt16], from cursor: inout Int, quote: UInt16) -> SyntaxToken? {
        let start = cursor
        while cursor < units.count {
            if units[cursor] == 92 {
                cursor = min(units.count, cursor + 2)
                continue
            }
            if hasTriple(units, at: cursor, quote: quote) {
                cursor += 3
                state = .none
                return SyntaxToken(range: start..<cursor, kind: .string)
            }
            cursor += 1
        }
        return nil
    }

    private mutating func scanSingleDelimiterEnd(
        _ units: [UInt16], from cursor: inout Int, delimiter: UInt16, clearsState: Bool
    ) -> SyntaxToken? {
        let start = cursor
        while cursor < units.count {
            if units[cursor] == 92 {
                cursor = min(units.count, cursor + 2)
                continue
            }
            if units[cursor] == delimiter {
                cursor += 1
                if clearsState { state = .none }
                return SyntaxToken(range: start..<cursor, kind: .string)
            }
            cursor += 1
        }
        return nil
    }

    func scanQuoted(
        _ units: [UInt16], from cursor: inout Int, quote: UInt16, escape: Bool
    ) -> SyntaxToken {
        let start = cursor
        cursor += 1
        while cursor < units.count {
            let ch = units[cursor]
            if escape && ch == 92 {
                cursor = min(units.count, cursor + 2)
                continue
            }
            cursor += 1
            if ch == quote { break }
        }
        return SyntaxToken(range: start..<cursor, kind: .string)
    }

    func scanNumber(_ units: [UInt16], from cursor: inout Int) -> SyntaxToken {
        let start = cursor
        if units[cursor] == 45 { cursor += 1 }
        while cursor < units.count {
            let ch = units[cursor]
            if isDigit(ch) || ch == 95 || ch == 46 || (65...70).contains(ch) || (97...102).contains(ch)
                || ch == 120 || ch == 88 || ch == 98 || ch == 111
            {
                cursor += 1
            } else {
                break
            }
        }
        return SyntaxToken(range: start..<cursor, kind: .number)
    }

    func scanIdentifier(_ units: [UInt16], from cursor: inout Int, spec: SyntaxLanguageSpec) -> SyntaxToken? {
        let start = cursor
        cursor += 1
        while cursor < units.count, isIdentCont(units[cursor]) { cursor += 1 }
        let word = String(utf16CodeUnits: Array(units[start..<cursor]), count: cursor - start)
        if spec.keywords.contains(word) {
            return SyntaxToken(range: start..<cursor, kind: .keyword)
        }
        if (65...90).contains(units[start]), word.utf16.contains(where: { (97...122).contains($0) }) {
            return SyntaxToken(range: start..<cursor, kind: .type)
        }
        return nil
    }

    private func findTwoChar(_ units: [UInt16], from start: Int, first: UInt16, second: UInt16) -> Int? {
        var idx = start
        while idx + 1 < units.count {
            if units[idx] == first && units[idx + 1] == second { return idx + 2 }
            idx += 1
        }
        return nil
    }

    func hasTriple(_ units: [UInt16], at idx: Int, quote: UInt16) -> Bool {
        idx + 2 < units.count && units[idx] == quote && units[idx + 1] == quote && units[idx + 2] == quote
    }

    func nextNonWhitespace(_ units: [UInt16], from start: Int) -> UInt16? {
        var idx = start
        while idx < units.count, isWhitespace(units[idx]) { idx += 1 }
        return idx < units.count ? units[idx] : nil
    }

    private func isLineLeading(_ units: [UInt16], before index: Int) -> Bool {
        (0..<index).allSatisfy { isWhitespace(units[$0]) }
    }

    func isWhitespace(_ ch: UInt16) -> Bool { ch == 32 || ch == 9 || ch == 13 }
    func isDigit(_ ch: UInt16) -> Bool { (48...57).contains(ch) }
    func isIdentStart(_ ch: UInt16) -> Bool {
        (65...90).contains(ch) || (97...122).contains(ch) || ch == 95 || ch == 36
    }
    func isIdentCont(_ ch: UInt16) -> Bool { isIdentStart(ch) || isDigit(ch) }
}
