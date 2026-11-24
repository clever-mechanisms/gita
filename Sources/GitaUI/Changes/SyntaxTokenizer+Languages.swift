import Foundation

/// Supported programming and markup languages for zero-dependency syntax highlighting.
enum SyntaxLanguage: String, CaseIterable, Sendable {
    case swift
    case objectiveC
    case cFamily
    case javascript
    case typescript
    case go
    case rust
    case java
    case kotlin
    case python
    case shell
    case json
    case yaml
    case toml
    case markdown

    init?(path: String?) {
        guard let path, !path.isEmpty else { return nil }
        let file = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        if let special = Self.specialFilenames[file] {
            self = special
            return
        }
        let ext = URL(fileURLWithPath: file).pathExtension
        guard let matched = Self.extensionMap[ext] else { return nil }
        self = matched
    }

    private static let specialFilenames: [String: Self] = [
        "makefile": .shell,
        "dockerfile": .shell,
        "podfile": .swift,
        "gemfile": .python,
        ".zshrc": .shell,
        ".bashrc": .shell,
        ".bash_profile": .shell,
    ]

    private static let extensionMap: [String: Self] = [
        "swift": .swift,
        "m": .objectiveC, "mm": .objectiveC,
        "c": .cFamily, "cc": .cFamily, "cpp": .cFamily, "cxx": .cFamily,
        "h": .cFamily, "hh": .cFamily, "hpp": .cFamily, "hxx": .cFamily,
        "js": .javascript, "jsx": .javascript, "mjs": .javascript, "cjs": .javascript,
        "ts": .typescript, "tsx": .typescript, "mts": .typescript, "cts": .typescript,
        "go": .go,
        "rs": .rust,
        "java": .java,
        "kt": .kotlin, "kts": .kotlin,
        "py": .python, "pyw": .python,
        "sh": .shell, "bash": .shell, "zsh": .shell, "fish": .shell,
        "json": .json, "jsonc": .json,
        "yml": .yaml, "yaml": .yaml,
        "toml": .toml,
        "md": .markdown, "markdown": .markdown,
    ]
}

struct SyntaxLanguageSpec: Sendable {
    enum Family: Sendable {
        case cLike
        case python
        case shell
        case json
        case yaml
        case toml
        case markdown
    }

    let family: Family
    let keywords: Set<String>
    let supportsBacktickStrings: Bool
    let supportsTripleQuotes: Bool
    let supportsPreprocessor: Bool
    let supportsAtKeyword: Bool
}

extension SyntaxLanguage {
    private static let specs: [Self: SyntaxLanguageSpec] = [
        .swift: SyntaxLanguageSpec(
            family: .cLike, keywords: swiftKeywords, supportsBacktickStrings: false,
            supportsTripleQuotes: true, supportsPreprocessor: true, supportsAtKeyword: true),
        .objectiveC: SyntaxLanguageSpec(
            family: .cLike, keywords: objcKeywords, supportsBacktickStrings: false,
            supportsTripleQuotes: false, supportsPreprocessor: true, supportsAtKeyword: true),
        .cFamily: SyntaxLanguageSpec(
            family: .cLike, keywords: cKeywords, supportsBacktickStrings: false,
            supportsTripleQuotes: false, supportsPreprocessor: true, supportsAtKeyword: false),
        .javascript: SyntaxLanguageSpec(
            family: .cLike, keywords: jsKeywords, supportsBacktickStrings: true,
            supportsTripleQuotes: false, supportsPreprocessor: false, supportsAtKeyword: false),
        .typescript: SyntaxLanguageSpec(
            family: .cLike, keywords: tsKeywords, supportsBacktickStrings: true,
            supportsTripleQuotes: false, supportsPreprocessor: false, supportsAtKeyword: false),
        .go: SyntaxLanguageSpec(
            family: .cLike, keywords: goKeywords, supportsBacktickStrings: true,
            supportsTripleQuotes: false, supportsPreprocessor: false, supportsAtKeyword: false),
        .rust: SyntaxLanguageSpec(
            family: .cLike, keywords: rustKeywords, supportsBacktickStrings: false,
            supportsTripleQuotes: false, supportsPreprocessor: true, supportsAtKeyword: false),
        .java: SyntaxLanguageSpec(
            family: .cLike, keywords: javaKeywords, supportsBacktickStrings: false,
            supportsTripleQuotes: false, supportsPreprocessor: false, supportsAtKeyword: true),
        .kotlin: SyntaxLanguageSpec(
            family: .cLike, keywords: kotlinKeywords, supportsBacktickStrings: false,
            supportsTripleQuotes: true, supportsPreprocessor: false, supportsAtKeyword: true),
        .python: SyntaxLanguageSpec(
            family: .python, keywords: pythonKeywords, supportsBacktickStrings: false,
            supportsTripleQuotes: true, supportsPreprocessor: false, supportsAtKeyword: true),
        .shell: SyntaxLanguageSpec(
            family: .shell, keywords: shellKeywords, supportsBacktickStrings: true,
            supportsTripleQuotes: false, supportsPreprocessor: false, supportsAtKeyword: false),
        .json: SyntaxLanguageSpec(
            family: .json, keywords: ["true", "false", "null"], supportsBacktickStrings: false,
            supportsTripleQuotes: false, supportsPreprocessor: false, supportsAtKeyword: false),
        .yaml: SyntaxLanguageSpec(
            family: .yaml, keywords: ["true", "false", "null", "yes", "no"], supportsBacktickStrings: false,
            supportsTripleQuotes: false, supportsPreprocessor: false, supportsAtKeyword: false),
        .toml: SyntaxLanguageSpec(
            family: .toml, keywords: ["true", "false"], supportsBacktickStrings: false,
            supportsTripleQuotes: true, supportsPreprocessor: false, supportsAtKeyword: false),
        .markdown: SyntaxLanguageSpec(
            family: .markdown, keywords: [], supportsBacktickStrings: true,
            supportsTripleQuotes: false, supportsPreprocessor: false, supportsAtKeyword: false),
    ]

    var spec: SyntaxLanguageSpec {
        Self.specs[self]
            ?? SyntaxLanguageSpec(
                family: .cLike, keywords: [], supportsBacktickStrings: false,
                supportsTripleQuotes: false, supportsPreprocessor: false, supportsAtKeyword: false)
    }

    private static let swiftKeywords: Set<String> = [
        "actor", "any", "as", "async", "await", "break", "case", "catch", "class", "continue", "default", "defer",
        "deinit", "do", "else", "enum", "extension", "fallthrough", "false", "fileprivate", "final", "for", "func",
        "guard", "if", "import", "in", "init", "inout", "internal", "is", "isolated", "lazy", "let", "mutating",
        "nil", "nonisolated", "open", "operator", "override", "private", "protocol", "public", "repeat", "required",
        "rethrows", "return", "self", "Self", "some", "static", "struct", "subscript", "super", "switch", "throw",
        "throws", "true", "try", "typealias", "var", "weak", "where", "while",
    ]
    private static let cKeywords: Set<String> = [
        "auto", "bool", "break", "case", "char", "class", "const", "constexpr", "continue", "default", "delete", "do",
        "double", "else", "enum", "explicit", "extern", "false", "float", "for", "friend", "goto", "if", "inline",
        "int", "long", "namespace", "new", "noexcept", "nullptr", "operator", "override", "private", "protected",
        "public", "register", "return", "short", "signed", "sizeof", "static", "struct", "switch", "template", "this",
        "throw", "true", "typedef", "typename", "union", "unsigned", "using", "virtual", "void", "volatile", "while",
    ]
    private static let objcKeywords: Set<String> = cKeywords.union([
        "id", "instancetype", "nil", "Nil", "NO", "SEL", "YES", "nonatomic", "atomic", "strong", "weak", "copy",
        "readonly", "readwrite", "assign",
    ])
    private static let jsKeywords: Set<String> = [
        "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete",
        "do", "else", "export", "extends", "false", "finally", "for", "from", "function", "if", "import", "in",
        "instanceof", "let", "new", "null", "of", "return", "static", "super", "switch", "this", "throw", "true",
        "try", "typeof", "undefined", "var", "void", "while", "with", "yield",
    ]
    private static let tsKeywords: Set<String> = jsKeywords.union([
        "abstract", "as", "declare", "enum", "implements", "interface", "is", "keyof", "namespace", "never",
        "private", "protected", "public", "readonly", "satisfies", "type", "unknown",
    ])
    private static let goKeywords: Set<String> = [
        "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "false", "for",
        "func", "go", "goto", "if", "import", "interface", "map", "nil", "package", "range", "return", "select",
        "struct", "switch", "true", "type", "var",
    ]
    private static let rustKeywords: Set<String> = [
        "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false", "fn",
        "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self",
        "Self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while",
    ]
    private static let javaKeywords: Set<String> = [
        "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class", "const", "continue",
        "default", "do", "double", "else", "enum", "extends", "false", "final", "finally", "float", "for", "if",
        "implements", "import", "instanceof", "int", "interface", "long", "native", "new", "null", "package",
        "private", "protected", "public", "record", "return", "sealed", "short", "static", "super", "switch",
        "synchronized", "this", "throw", "throws", "transient", "true", "try", "var", "void", "volatile", "while",
    ]
    private static let kotlinKeywords: Set<String> = [
        "abstract", "actual", "annotation", "as", "break", "by", "class", "companion", "const", "constructor",
        "continue", "data", "do", "else", "enum", "expect", "false", "final", "finally", "for", "fun", "if",
        "import", "in", "infix", "init", "inline", "inner", "interface", "internal", "is", "lateinit", "null",
        "object", "open", "operator", "override", "package", "private", "protected", "public", "return", "sealed",
        "super", "suspend", "this", "throw", "true", "try", "typealias", "val", "var", "when", "where", "while",
    ]
    private static let pythonKeywords: Set<String> = [
        "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except",
        "False", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "None", "nonlocal", "not",
        "or", "pass", "raise", "return", "True", "try", "while", "with", "yield",
    ]
    private static let shellKeywords: Set<String> = [
        "case", "do", "done", "elif", "else", "esac", "export", "fi", "for", "function", "if", "in", "local",
        "readonly", "return", "select", "then", "until", "while",
    ]
}

/// Data-format and markup line tokenizers (`JSON`, `YAML`, `TOML`, `Markdown`).
extension SyntaxTokenizer {
    func tokenizeJSON(_ units: [UInt16]) -> [SyntaxToken] {
        var tokens: [SyntaxToken] = []
        var cursor = 0
        while cursor < units.count {
            let ch = units[cursor]
            if isWhitespace(ch) {
                cursor += 1
            } else if ch == 47, cursor + 1 < units.count, units[cursor + 1] == 47 {
                tokens.append(SyntaxToken(range: cursor..<units.count, kind: .comment))
                break
            } else if ch == 34 {
                let token = scanQuoted(units, from: &cursor, quote: 34, escape: true)
                let isKey = nextNonWhitespace(units, from: cursor) == 58
                tokens.append(SyntaxToken(range: token.range, kind: isKey ? .property : .string))
            } else if isDigit(ch) || (ch == 45 && cursor + 1 < units.count && isDigit(units[cursor + 1])) {
                tokens.append(scanNumber(units, from: &cursor))
            } else if isIdentStart(ch) {
                if let ident = scanIdentifier(units, from: &cursor, spec: SyntaxLanguage.json.spec) {
                    tokens.append(ident)
                }
            } else {
                cursor += 1
            }
        }
        return tokens
    }

    func tokenizeYAML(_ units: [UInt16], spec: SyntaxLanguageSpec) -> [SyntaxToken] {
        var tokens: [SyntaxToken] = []
        var cursor = 0
        while cursor < units.count, isWhitespace(units[cursor]) { cursor += 1 }
        if cursor < units.count, units[cursor] == 35 {
            return [SyntaxToken(range: cursor..<units.count, kind: .comment)]
        }
        if let colon = findYAMLKeyColon(units, from: cursor) {
            tokens.append(SyntaxToken(range: cursor..<colon, kind: .property))
            cursor = colon + 1
        }
        while cursor < units.count {
            let ch = units[cursor]
            if ch == 35 && (cursor == 0 || isWhitespace(units[cursor - 1])) {
                tokens.append(SyntaxToken(range: cursor..<units.count, kind: .comment))
                break
            }
            if ch == 34 || ch == 39 {
                tokens.append(scanQuoted(units, from: &cursor, quote: ch, escape: ch == 34))
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

    mutating func tokenizeTOML(_ units: [UInt16], spec: SyntaxLanguageSpec) -> [SyntaxToken] {
        var tokens: [SyntaxToken] = []
        var cursor = 0
        if state == .tripleDoubleQuote || state == .tripleSingleQuote {
            let quote: UInt16 = state == .tripleDoubleQuote ? 34 : 39
            guard let closed = scanTripleEnd(units, from: &cursor, quote: quote) else {
                return [SyntaxToken(range: 0..<units.count, kind: .string)]
            }
            tokens.append(closed)
        }
        skipLeadingWhitespace(units, cursor: &cursor)
        if let heading = scanTOMLHeading(units, cursor: &cursor) { tokens.append(heading) }
        while cursor < units.count {
            if units[cursor] == 35 {
                tokens.append(SyntaxToken(range: cursor..<units.count, kind: .comment))
                break
            }
            if let token = scanTOMLValueOrKey(units, cursor: &cursor, spec: spec) {
                tokens.append(token)
            }
        }
        return tokens
    }

    private func skipLeadingWhitespace(_ units: [UInt16], cursor: inout Int) {
        while cursor < units.count, isWhitespace(units[cursor]) { cursor += 1 }
    }

    private func scanTOMLHeading(_ units: [UInt16], cursor: inout Int) -> SyntaxToken? {
        guard cursor < units.count, units[cursor] == 91 else { return nil }
        let start = cursor
        while cursor < units.count, units[cursor] != 93 { cursor += 1 }
        if cursor < units.count { cursor += 1 }
        return SyntaxToken(range: start..<cursor, kind: .heading)
    }

    private mutating func scanTOMLValueOrKey(
        _ units: [UInt16], cursor: inout Int, spec: SyntaxLanguageSpec
    ) -> SyntaxToken? {
        let ch = units[cursor]
        if let str = scanStringIfAny(units, from: &cursor, spec: spec) { return str }
        if isDigit(ch) { return scanNumber(units, from: &cursor) }
        if isIdentStart(ch) {
            let start = cursor
            let ident = scanIdentifier(units, from: &cursor, spec: spec)
            return nextNonWhitespace(units, from: cursor) == 61
                ? SyntaxToken(range: start..<cursor, kind: .property)
                : ident
        }
        cursor += 1
        return nil
    }

    func tokenizeMarkdown(_ units: [UInt16]) -> [SyntaxToken] {
        var cursor = 0
        skipLeadingWhitespace(units, cursor: &cursor)
        guard cursor < units.count else { return [] }
        if units[cursor] == 35 {
            return [SyntaxToken(range: cursor..<units.count, kind: .heading)]
        }
        if hasTriple(units, at: cursor, quote: 96) {
            return [SyntaxToken(range: cursor..<units.count, kind: .preprocessor)]
        }
        var tokens: [SyntaxToken] = []
        while cursor < units.count {
            if units[cursor] == 96 {
                let start = cursor
                cursor += 1
                while cursor < units.count, units[cursor] != 96 { cursor += 1 }
                if cursor < units.count { cursor += 1 }
                tokens.append(SyntaxToken(range: start..<cursor, kind: .string))
            } else {
                cursor += 1
            }
        }
        return tokens
    }

    private func findYAMLKeyColon(_ units: [UInt16], from start: Int) -> Int? {
        var idx = start
        if idx < units.count, units[idx] == 45 {
            idx += 1
            skipLeadingWhitespace(units, cursor: &idx)
        }
        guard idx < units.count, isIdentStart(units[idx]) else { return nil }
        for scan in idx..<units.count {
            let ch = units[scan]
            if isYAMLKeyStop(ch) { return nil }
            if ch == 58, scan + 1 == units.count || isWhitespace(units[scan + 1]) { return scan }
        }
        return nil
    }

    private func isYAMLKeyStop(_ ch: UInt16) -> Bool {
        ch == 34 || ch == 39 || ch == 35 || ch == 123 || ch == 91
    }
}
