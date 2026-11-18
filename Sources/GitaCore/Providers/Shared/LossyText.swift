import Foundation

/// Text from bytes that should be UTF-8 but may not be (CLI stderr, process paths). Invalid UTF-8 falls back to
/// Latin-1 so ASCII keywords and separators survive instead of the whole text being dropped.
enum LossyText {
    static func decode<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        let array = Array(bytes)
        return String(bytes: array, encoding: .utf8) ?? String(bytes: array, encoding: .isoLatin1) ?? ""
    }
}
