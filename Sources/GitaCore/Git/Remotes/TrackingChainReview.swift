import Darwin
import Foundation

/// The refs one remote's symbolic tracking review follows, and the identity of what it saw.
struct TrackingChainReview {
    static let rootLimit = 128
    static let chainLimit = 16
    static let deadline: Duration = .seconds(20)

    let prefix: String
    var identity = Fingerprint()
    var existing = Set<String>()
    var roots = Set<String>()
    var exact = Set<String>()
    private let end = ContinuousClock.now.advanced(by: deadline)

    init(remote: String) { prefix = "refs/remotes/" + remote + "/" }

    /// Listed tracking refs (symbolic ones become roots) and exact fetch destinations: broken symbolic refs may be
    /// omitted by for-each-ref, so an exact destination is inspected directly even when not listed.
    mutating func collect(references: Data, fetch selected: [RemoteConfigEntry]) -> Bool {
        for record in references.split(separator: GitOutput.lineFeed) {
            let fields = record.split(separator: GitOutput.nul, omittingEmptySubsequences: false)
            guard fields.count == 4, fields[3].isEmpty, let ref = String(data: Data(fields[0]), encoding: .utf8),
                ref.utf8.starts(with: prefix.utf8), GitParsers.isObjectID(String(decoding: fields[1], as: UTF8.self))
            else { return false }
            existing.insert(ref)
            if !fields[2].isEmpty { roots.insert(ref) }
        }
        for entry in selected where entry.variable == "fetch" {
            guard let destination = FetchRefspec(entry.value)?.destination, !destination.contains("*") else { continue }
            exact.insert(destination)
            roots.insert(destination)
        }
        return roots.count <= Self.rootLimit
    }

    func mayVisit(_ ref: String, visited: Set<String>) -> Bool {
        ContinuousClock.now < end && visited.count < Self.chainLimit && !visited.contains(ref)
            && ref.utf8.starts(with: prefix.utf8) && ref.utf8.count > prefix.utf8.count && ref.utf8.count <= 1_024
    }
}
