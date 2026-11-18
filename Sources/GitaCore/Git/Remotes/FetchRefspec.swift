import Foundation

/// One `remote.<name>.fetch` value: `[+]<source>:<destination>`, or a negative `^<source>`.
struct FetchRefspec: Equatable {
    var isNegative: Bool
    var isForced: Bool
    /// Nil for a negative refspec or one without a destination.
    var destination: String?

    init?(_ value: String) {
        isNegative = value.hasPrefix("^")
        let body = isNegative ? String(value.dropFirst()) : value
        isForced = !isNegative && body.hasPrefix("+")
        let spec = isForced ? String(body.dropFirst()) : body
        if isNegative {
            guard !spec.isEmpty else { return nil }
            destination = nil
            return
        }
        guard let colon = spec.lastIndex(of: ":") else {
            destination = nil
            return
        }
        destination = String(spec[spec.index(after: colon)...])
    }

    /// Whether `fullName` is a ref this refspec writes: the exact destination, or a match of its single `*`.
    func destinationMatches(_ fullName: String) -> Bool {
        guard !isNegative, let destination else { return false }
        let pieces = destination.split(separator: "*", omittingEmptySubsequences: false)
        if pieces.count == 1 { return GitOutput.same(destination, fullName) }
        return pieces.count == 2 && fullName.utf8.starts(with: pieces[0].utf8)
            && fullName.utf8.count >= pieces[0].utf8.count + pieces[1].utf8.count
            && fullName.utf8.reversed().starts(with: pieces[1].utf8.reversed())
    }

    /// The fixed part of the destination before any `*`.
    var destinationPrefix: String? { destination.map { String($0.prefix { $0 != "*" }) } }
}
