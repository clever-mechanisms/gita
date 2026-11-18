import CryptoKit
import Foundation

/// An opaque review identity: labelled, length-framed parts hashed together, so no two different sequences of parts
/// produce the same bytes. Fingerprints are compared in memory only and never stored.
struct Fingerprint {
    private var hash = SHA256()

    /// `nil` (absent) and empty data are different parts.
    mutating func add(_ label: String, _ data: Data?) {
        let labelBytes = Data(label.utf8)
        hash.update(data: Data("\(labelBytes.count):".utf8))
        hash.update(data: labelBytes)
        hash.update(data: Data("\(data?.count ?? -1):".utf8))
        if let data { hash.update(data: data) }
    }

    mutating func add(_ label: String, _ text: String?) { add(label, text.map { Data($0.utf8) }) }

    var hex: String { hash.finalize().hexString }
}

extension Sequence where Element == UInt8 {
    /// Lower-case hexadecimal, two digits per byte.
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

extension Data {
    var sha256Hex: String { SHA256.hash(data: self).hexString }
}
