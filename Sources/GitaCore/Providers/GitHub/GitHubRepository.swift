import Foundation

/// A validated github.com `owner/name`. Both parts are safe as command arguments and URL path components.
struct GitHubRepository: Sendable, Hashable {
    let owner: String
    let name: String

    var nameWithOwner: String { owner + "/" + name }
    /// Hosted identity used to tell reports of different repositories apart.
    var sourceID: String { "github:" + nameWithOwner.lowercased() }

    private static let maximumLength = 201

    /// An `owner/name` the app already validated once (a provider target).
    init?(nameWithOwner value: String) {
        guard !value.hasSuffix(".git") else { return nil }
        self.init(path: value)
    }

    /// A remote's `owner/name` path, without `.git`.
    init?(path value: String) {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard value.utf8.count <= Self.maximumLength, parts.count == 2, parts.allSatisfy(Self.isValidPart) else {
            return nil
        }
        owner = String(parts[0])
        name = String(parts[1])
    }

    private static func isValidPart(_ part: Substring) -> Bool {
        !part.isEmpty && part != "." && part != ".." && !part.hasPrefix("-")
            && ProviderValidation.consists(part, of: ProviderValidation.slugCharacters)
    }
}
