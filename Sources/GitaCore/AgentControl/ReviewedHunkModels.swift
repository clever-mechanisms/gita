import Foundation

public struct ReviewedHunkHash: RawRepresentable, Sendable, Hashable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public enum ReviewedHunkHasher {
    public static func hash(filePath: String, hunkLines: [String]) -> ReviewedHunkHash {
        var fingerprint = Fingerprint()
        fingerprint.add("path", filePath)
        for line in hunkLines where ["+", "-", " "].contains(line.first) {
            fingerprint.add("line", line)
        }
        return ReviewedHunkHash(rawValue: fingerprint.hex)
    }

    public static func hash(filePath: String, hunkPatch: String) -> ReviewedHunkHash {
        let lines = hunkPatch.utf8.split(separator: 10).map { String(decoding: $0, as: UTF8.self) }
        let body = lines.drop(while: { !$0.hasPrefix("@@ ") }).dropFirst().prefix { !$0.hasPrefix("diff --git ") }
        return hash(filePath: filePath, hunkLines: Array(body))
    }
}

struct ReviewedHunkRecord: Codable, Sendable, Hashable {
    let hash: ReviewedHunkHash
    let filePath: String
    let reviewedAt: Date
}

public enum ReviewedHunkFilterMode: String, Sendable, CaseIterable, Hashable {
    case all, unreviewedOnly, reviewedOnly
}

public struct ReviewedHunksProgress: Sendable, Equatable {
    public let reviewed: Int
    public let total: Int
    public var isComplete: Bool { reviewed == total }
    public var remaining: Int { total - reviewed }
}
