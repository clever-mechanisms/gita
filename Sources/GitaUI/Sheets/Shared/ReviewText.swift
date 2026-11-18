import Foundation

/// Text rules the review sheets share: exact comparison of Git names, full object IDs, short reference names and
/// bounded error messages.
enum ReviewText {
    /// Longest error text a sheet shows; Git can print far more.
    static let errorLimit = 1_000
    private static let fullObjectIDLengths: Set<Int> = [40, 64]
    private static let referencePrefixes = ["refs/heads/", "refs/remotes/", "refs/tags/"]

    /// Byte-for-byte equality: Git names are not Unicode-normalized, so canonically equal strings can differ.
    static func same(_ left: String, _ right: String) -> Bool { left.utf8.elementsEqual(right.utf8) }

    /// A complete SHA-1 or SHA-256 object name in hexadecimal.
    static func isFullObjectID(_ value: String) -> Bool {
        fullObjectIDLengths.contains(value.utf8.count) && value.utf8.allSatisfy(isHexDigit)
    }

    /// `refs/heads/main` → `main`, `refs/remotes/origin/main` → `origin/main`, `refs/tags/v1` → `v1`.
    static func shortReference(_ value: String) -> String {
        for prefix in referencePrefixes where value.hasPrefix(prefix) {
            return String(value.dropFirst(prefix.count))
        }
        return value
    }

    static func message(_ error: any Error) -> String { clipped(error.localizedDescription) }
    static func clipped(_ text: String) -> String { String(text.prefix(errorLimit)) }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(byte)
    }
}
