import Foundation

/// Just enough TOML to find, replace, insert or delete the top-level `notify` array of strings without disturbing the
/// rest of the file (comments, tables, multi-line strings and arrays stay byte-for-byte).
enum TOMLNotify {
    /// UTF-8 offsets of the whole `notify = …` line(s). A value that is not a one-line-per-item array of strings is
    /// not readable, and its `values` are empty.
    struct Match {
        var range: Range<Int>
        var values: [String]
        var isReadable: Bool
    }

    static func find(in text: String) -> Match? {
        let bytes = Array(text.utf8)
        var index = 0
        while index < bytes.count {
            let lineStart = index
            while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x09 { index += 1 }
            guard index < bytes.count else { return nil }
            if bytes[index] == UInt8(ascii: "[") { return nil } // first table: top level ends
            if startsKey("notify", bytes, index) {
                guard let (end, values) = parseAssignment(bytes, from: index + 6) else {
                    return Match(range: lineStart..<skipStatement(bytes, from: index), values: [], isReadable: false)
                }
                var lineEnd = end
                while lineEnd < bytes.count, bytes[lineEnd] != 0x0A { lineEnd += 1 }
                if lineEnd < bytes.count { lineEnd += 1 }
                return Match(range: lineStart..<lineEnd, values: values, isReadable: true)
            }
            index = skipStatement(bytes, from: index)
        }
        return nil
    }

    static func replacing(_ match: Match, in text: String, with values: [String]) -> String {
        splicing(match, in: text, with: Array((render(values) + "\n").utf8))
    }

    static func removing(_ match: Match, from text: String) -> String {
        splicing(match, in: text, with: [])
    }

    private static func splicing(_ match: Match, in text: String, with line: [UInt8]) -> String {
        var bytes = Array(text.utf8)
        bytes.replaceSubrange(match.range, with: line)
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Before the first table header (top-level keys must precede tables), else at the end.
    static func inserting(_ values: [String], into text: String) -> String {
        var bytes = Array(text.utf8)
        var index = 0
        var insertion = bytes.count
        while index < bytes.count {
            let lineStart = index
            while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x09 { index += 1 }
            if index < bytes.count, bytes[index] == UInt8(ascii: "[") {
                insertion = lineStart
                break
            }
            index = skipStatement(bytes, from: index)
        }
        var line = Array((render(values) + "\n").utf8)
        if insertion == bytes.count, let last = bytes.last, last != 0x0A { line.insert(0x0A, at: 0) }
        bytes.insert(contentsOf: line, at: insertion)
        return String(decoding: bytes, as: UTF8.self)
    }

    static func render(_ values: [String]) -> String {
        "notify = [" + values.map(quoted).joined(separator: ", ") + "]"
    }

    static func quoted(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\t": result += "\\t"
            case "\r": result += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    result += String(format: "\\u%04X", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }

    private static func startsKey(_ key: String, _ bytes: [UInt8], _ index: Int) -> Bool {
        let key = Array(key.utf8)
        guard index + key.count <= bytes.count, Array(bytes[index..<index + key.count]) == key else { return false }
        var next = index + key.count
        while next < bytes.count, bytes[next] == 0x20 || bytes[next] == 0x09 { next += 1 }
        return next < bytes.count && bytes[next] == UInt8(ascii: "=")
    }

    /// `= [ "a", 'b', ]` → end offset and values; nil when the value is not an array of strings.
    private static func parseAssignment(_ bytes: [UInt8], from start: Int) -> (Int, [String])? {
        var index = start
        func skipSpace(newlines: Bool) {
            while index < bytes.count {
                let byte = bytes[index]
                if byte == 0x20 || byte == 0x09 || (newlines && (byte == 0x0A || byte == 0x0D)) {
                    index += 1
                } else if newlines && byte == UInt8(ascii: "#") {
                    while index < bytes.count, bytes[index] != 0x0A { index += 1 }
                } else {
                    break
                }
            }
        }
        skipSpace(newlines: false)
        guard index < bytes.count, bytes[index] == UInt8(ascii: "=") else { return nil }
        index += 1
        skipSpace(newlines: false)
        guard index < bytes.count, bytes[index] == UInt8(ascii: "[") else { return nil }
        index += 1
        var values: [String] = []
        while true {
            skipSpace(newlines: true)
            guard index < bytes.count else { return nil }
            if bytes[index] == UInt8(ascii: "]") { return (index + 1, values) }
            guard let (end, value) = parseString(bytes, from: index) else { return nil }
            values.append(value)
            index = end
            skipSpace(newlines: true)
            guard index < bytes.count else { return nil }
            if bytes[index] == UInt8(ascii: ",") { index += 1 } else if bytes[index] != UInt8(ascii: "]") { return nil }
        }
    }

    private static func parseString(_ bytes: [UInt8], from start: Int) -> (Int, String)? {
        guard start < bytes.count else { return nil }
        let quote = bytes[start]
        guard quote == UInt8(ascii: "\"") || quote == UInt8(ascii: "'") else { return nil }
        // multi-line: unsupported
        guard !isTripleQuote(bytes, at: start) else { return nil }
        var index = start + 1
        var output: [UInt8] = []
        while index < bytes.count {
            let byte = bytes[index]
            if byte == quote { return (index + 1, String(decoding: output, as: UTF8.self)) }
            if byte == 0x0A { return nil }
            if quote == UInt8(ascii: "\""), byte == UInt8(ascii: "\\"), index + 1 < bytes.count {
                guard let (decoded, length) = escape(bytes, at: index) else { return nil }
                output.append(contentsOf: decoded)
                index += length
                continue
            }
            output.append(byte)
            index += 1
        }
        return nil
    }

    /// The bytes a basic-string escape at `index` (its backslash) stands for, and how many bytes it spans.
    private static func escape(_ bytes: [UInt8], at index: Int) -> ([UInt8], Int)? {
        let escape = bytes[index + 1]
        if let simple = simpleEscapes[escape] { return ([simple], 2) }
        guard escape == UInt8(ascii: "u") || escape == UInt8(ascii: "U") else { return nil }
        let length = escape == UInt8(ascii: "u") ? 4 : 8
        guard index + 2 + length <= bytes.count,
            let value = UInt32(String(decoding: bytes[(index + 2)..<(index + 2 + length)], as: UTF8.self), radix: 16),
            let scalar = Unicode.Scalar(value)
        else { return nil }
        return (Array(String(scalar).utf8), 2 + length)
    }

    private static let simpleEscapes: [UInt8: UInt8] = [
        UInt8(ascii: "n"): 0x0A, UInt8(ascii: "t"): 0x09, UInt8(ascii: "r"): 0x0D,
        UInt8(ascii: "\""): UInt8(ascii: "\""), UInt8(ascii: "\\"): UInt8(ascii: "\\"),
    ]

    private static func isTripleQuote(_ bytes: [UInt8], at index: Int) -> Bool {
        index + 2 < bytes.count && bytes[index + 1] == bytes[index] && bytes[index + 2] == bytes[index]
    }

    /// Skips one top-level statement (to the end of its value, which may span lines inside arrays, inline tables or
    /// multi-line strings) and returns the offset of the next line.
    private static func skipStatement(_ bytes: [UInt8], from start: Int) -> Int {
        var index = start
        var depth = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "#") {
                while index < bytes.count, bytes[index] != 0x0A { index += 1 }
                continue
            }
            if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
                index = skipString(bytes, from: index)
                continue
            }
            if byte == UInt8(ascii: "[") || byte == UInt8(ascii: "{") { depth += 1 }
            if byte == UInt8(ascii: "]") || byte == UInt8(ascii: "}") { depth = max(0, depth - 1) }
            if byte == 0x0A && depth == 0 { return index + 1 }
            index += 1
        }
        return bytes.count
    }

    /// The offset after the string (single-line or multi-line) that starts at `start`; a basic string's
    /// backslash escapes the next byte.
    private static func skipString(_ bytes: [UInt8], from start: Int) -> Int {
        let quote = bytes[start]
        let escapes = quote == UInt8(ascii: "\"")
        var index = start
        if isTripleQuote(bytes, at: start) {
            index += 3
            while index + 2 < bytes.count, !(bytes[index] == quote && isTripleQuote(bytes, at: index)) {
                index += escapes && bytes[index] == UInt8(ascii: "\\") ? 2 : 1
            }
            return min(bytes.count, index + 3)
        }
        index += 1
        while index < bytes.count, bytes[index] != quote, bytes[index] != 0x0A {
            index += escapes && bytes[index] == UInt8(ascii: "\\") ? 2 : 1
        }
        return index + 1
    }
}
