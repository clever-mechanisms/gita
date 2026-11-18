import Foundation

/// Reading Git's line output byte-exactly. Commands without a NUL mode end their value with exactly one LF; a
/// path may itself end in CR or LF, so only that one LF byte is removed. (Swift treats "\r\n" as one Character, so
/// `hasSuffix("\n")` is false for a value ending in CRLF.)
enum GitOutput {
    static let lineFeed = UInt8(ascii: "\n")
    static let nul: UInt8 = 0

    static func withoutTerminalLF(_ value: String) -> String {
        guard value.utf8.last == lineFeed else { return value }
        return String(decoding: value.utf8.dropLast(), as: UTF8.self)
    }

    /// The value without its terminal LF, or nil when it is not valid UTF-8.
    static func line(_ data: Data) -> String? {
        String(data: data.last == lineFeed ? data.dropLast() : data, encoding: .utf8)
    }

    /// Non-empty LF-separated lines of a value, after removing its terminal LF.
    static func lines(_ value: String) -> [String] {
        withoutTerminalLF(value).split(separator: "\n").map(String.init)
    }

    /// NUL-separated fields, decoded as UTF-8 (lossy; for display data).
    static func nulFields(_ data: Data) -> [String] {
        data.split(separator: nul, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Byte equality: String equality would treat canonically equivalent spellings as equal.
    static func same(_ lhs: String, _ rhs: String) -> Bool { lhs.utf8.elementsEqual(rhs.utf8) }
}
