import Foundation

/// The HTML GitHub allows in comments, turned into the Markdown the review window draws, as bots write it (Vercel's
/// deployment tables, "Open in Cursor" badges): a link keeps its text, an image becomes its alt text (a link to the
/// image when it stands alone), block tags become line breaks, emphasis becomes Markdown, entities are decoded and
/// every other known tag is dropped with its text kept. Fenced and inline code is left exactly as written, and so is
/// anything that only looks like a tag (`Array<T>`).
enum ReviewHTML {
    static func markdown(_ text: String) -> String {
        var output: [String] = []
        var chunk: [String] = []
        var inFence = false
        func flush() {
            guard !chunk.isEmpty else { return }
            var converter = Converter(chunk.joined(separator: "\n"))
            output.append(tidy(converter.run()))
            chunk = []
        }
        for line in text.components(separatedBy: "\n") {
            let isFence = ReviewMarkdown.isFence(line)
            guard inFence || isFence else {
                chunk.append(line)
                continue
            }
            flush()
            output.append(line)
            if isFence { inFence.toggle() }
        }
        flush()
        return output.joined(separator: "\n")
    }

    /// Blank lines left by removed tags collapse to one.
    private static func tidy(_ text: String) -> String {
        var lines: [String] = []
        for line in text.components(separatedBy: "\n") {
            let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if blank, lines.last?.isEmpty ?? false { continue }
            lines.append(blank ? "" : line)
        }
        return lines.joined(separator: "\n")
    }

    /// One parsed tag: `<a href="…">`, `</a>`, `<img … />`.
    struct Tag: Equatable {
        var name: String
        var isClosing: Bool
        var attributes: [String: String]
    }

    /// The tag starting at `text`'s first character and its length, or nil when it isn't one the window knows.
    static func tag(at text: Substring) -> (tag: Tag, length: Int)? {
        guard text.first == "<", let end = text.firstIndex(of: ">") else { return nil }
        let inside = text[text.index(after: text.startIndex)..<end]
        guard !inside.contains("<") else { return nil }
        let isClosing = inside.first == "/"
        let body = isClosing ? inside.dropFirst() : inside
        let name = body.prefix { $0.isLetter || $0.isNumber || $0 == "-" }.lowercased()
        guard let first = name.first, first.isLetter, known.contains(name) else { return nil }
        let rest = body.dropFirst(name.count)
        guard rest.isEmpty || rest.first?.isWhitespace == true || rest.first == "/" else { return nil }
        let length = text.distance(from: text.startIndex, to: end) + 1
        return (Tag(name: name, isClosing: isClosing, attributes: attributes(String(rest))), length)
    }

    private static let attributePattern = try? NSRegularExpression(
        pattern: #"([A-Za-z][\w:-]*)\s*=\s*("[^"]*"|'[^']*'|[^\s"'>]+)"#)

    static func attributes(_ text: String) -> [String: String] {
        guard let pattern = attributePattern else { return [:] }
        var result: [String: String] = [:]
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let nameRange = Range(match.range(at: 1), in: text),
                let valueRange = Range(match.range(at: 2), in: text)
            else { continue }
            let name = text[nameRange].lowercased()
            var value = String(text[valueRange])
            if let quote = value.first, quote == "\"" || quote == "'" { value = String(value.dropFirst().dropLast()) }
            result[name] = value
        }
        return result
    }

    /// A link the window may open: web and mail addresses only.
    static func safeURL(_ value: String?) -> String? {
        guard let value = value.map(decodeEntities)?.trimmingCharacters(in: .whitespaces),
            let scheme = URL(string: value)?.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme),
            !value.contains(">"), !value.contains("\n")
        else { return nil }
        return value
    }

    static let entities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "#39": "'", "mdash": "—",
        "ndash": "–", "hellip": "…", "middot": "·", "copy": "©", "rarr": "→", "larr": "←",
    ]

    /// The entity at the start of `text` (`&amp;`, `&#8594;`) and its length, or nil.
    static func entity(at text: Substring) -> (value: String, length: Int)? {
        guard text.first == "&", let end = text.prefix(12).firstIndex(of: ";") else { return nil }
        let name = String(text[text.index(after: text.startIndex)..<end])
        let length = name.count + 2
        if let value = entities[name] { return (value, length) }
        guard name.hasPrefix("#") else { return nil }
        let digits = name.dropFirst()
        let code = digits.first == "x" || digits.first == "X" ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
        guard let code, code > 0, let scalar = Unicode.Scalar(code) else { return nil }
        return (String(Character(scalar)), length)
    }

    static func decodeEntities(_ text: String) -> String {
        var result = ""
        var rest = Substring(text)
        while let first = rest.first {
            if let entity = entity(at: rest) {
                result += entity.value
                rest = rest.dropFirst(entity.length)
            } else {
                result.append(first)
                rest = rest.dropFirst()
            }
        }
        return result
    }

    /// Tags that end a line, and the ones whose Markdown is a pair of markers.
    static let blockTags: Set<String> = [
        "p", "div", "br", "hr", "details", "summary", "table", "thead", "tbody", "tr", "ul", "ol", "blockquote",
        "pre", "h1", "h2", "h3", "h4", "h5", "h6", "center",
    ]
    static let markers: [String: String] = [
        "b": "**", "strong": "**", "i": "*", "em": "*", "code": "`", "del": "~~", "s": "~~",
    ]
    static let known: Set<String> = blockTags.union(markers.keys).union([
        "a", "img", "li", "td", "th", "span", "sup", "sub", "picture", "source", "relative-time", "kbd", "small",
        "u", "ins", "g-emoji", "font", "abbr", "samp", "var", "mark",
    ])
}

/// One pass over text outside fenced code. A link's text is gathered on its own until `</a>` closes it.
private struct Converter {
    private var rest: Substring
    private var buffers = [""]
    private var links: [String?] = []

    init(_ text: String) { rest = Substring(text) }

    mutating func run() -> String {
        while let first = rest.first {
            if first == "`" {
                code()
            } else if first == "<", let found = ReviewHTML.tag(at: rest) {
                rest = rest.dropFirst(found.length)
                handle(found.tag)
            } else if first == "&", let entity = ReviewHTML.entity(at: rest) {
                rest = rest.dropFirst(entity.length)
                append(entity.value)
            } else {
                append(String(first))
                rest = rest.dropFirst()
            }
        }
        while !links.isEmpty { closeLink() }
        return buffers.joined()
    }

    private mutating func append(_ text: String) { buffers[buffers.count - 1] += text }

    /// A code span, copied as written up to the matching run of backticks.
    private mutating func code() {
        let run = rest.prefix { $0 == "`" }
        let after = rest.dropFirst(run.count)
        guard let close = after.range(of: run) else {
            append(String(run))
            rest = after
            return
        }
        append(String(rest[rest.startIndex..<close.upperBound]))
        rest = rest[close.upperBound...]
    }

    private mutating func handle(_ tag: ReviewHTML.Tag) {
        switch tag.name {
        case "a":
            if tag.isClosing { closeLink() } else { openLink(tag) }
        case "img": image(tag)
        case "li": if !tag.isClosing { append("\n- ") }
        case "td", "th": if tag.isClosing { append(" ") }
        default:
            if ReviewHTML.blockTags.contains(tag.name) {
                append("\n")
            } else if let marker = ReviewHTML.markers[tag.name] {
                append(marker)
            }
        }
    }

    private mutating func openLink(_ tag: ReviewHTML.Tag) {
        links.append(ReviewHTML.safeURL(tag.attributes["href"]))
        buffers.append("")
    }

    /// `[text](<href>)`; a link with no text (an avatar) disappears, one without a usable address keeps its text.
    private mutating func closeLink() {
        guard let href = links.popLast() else { return }
        let text = (buffers.popLast() ?? "").components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        guard let href else {
            append(text)
            return
        }
        let escaped = text.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
        append("[\(escaped)](<\(href)>)")
    }

    /// Inside a link, its alt text; alone, a link to the image named by its alt text.
    private mutating func image(_ tag: ReviewHTML.Tag) {
        let alt = ReviewHTML.decodeEntities(tag.attributes["alt"] ?? "").trimmingCharacters(in: .whitespaces)
        guard links.isEmpty, let source = ReviewHTML.safeURL(tag.attributes["src"]) else {
            append(alt)
            return
        }
        append("[\(alt.isEmpty ? String(localized: "Image") : alt)](<\(source)>)")
    }
}
