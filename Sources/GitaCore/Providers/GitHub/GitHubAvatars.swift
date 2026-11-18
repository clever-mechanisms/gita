import Foundation

/// Author pictures for the history. Commit emails are matched to GitHub users through one read-only GraphQL query
/// over the default branch's recent history (the installed `gh` session; nothing is stored but public image URLs),
/// and GitHub's noreply addresses resolve without any request. Only `https` URLs on GitHub's avatar host are accepted.
public enum GitHubAvatars {
    public static let pixelSize = 64

    private static let noreplySuffix = "@users.noreply.github.com"
    private static let maximumLogin = 39
    private static let maximumURL = 512
    private static let maximumEmail = 320
    private static let loginCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")

    /// `12345+login@users.noreply.github.com` gives the numeric avatar; `login@users.noreply.github.com` the
    /// login's picture.
    public static func noreplyURL(email: String) -> URL? {
        let lower = email.lowercased()
        guard lower.hasSuffix(noreplySuffix) else { return nil }
        let local = String(lower.dropLast(noreplySuffix.count))
        let parts = local.split(separator: "+", maxSplits: 1).map(String.init)
        if parts.count == 2, let id = UInt64(parts[0]), id > 0, isLogin(parts[1]) {
            return URL(string: "https://avatars.githubusercontent.com/u/\(id)?s=\(pixelSize)&v=4")
        }
        guard parts.count == 1, isLogin(local) else { return nil }
        return URL(string: "https://avatars.githubusercontent.com/\(local)?s=\(pixelSize)")
    }

    /// Accepts only GitHub's avatar CDN over https, without credentials or odd ports.
    public static func validated(_ string: String) -> URL? {
        guard string.utf8.count <= maximumURL, let components = URLComponents(string: string),
            components.scheme == "https", components.host == "avatars.githubusercontent.com", components.user == nil,
            components.password == nil, components.port == nil
        else { return nil }
        return components.url
    }

    /// Email (lowercased) to avatar URL, from the `history` nodes of `GitHubQueries.avatars`.
    static func parse(
        _ envelope: GitHubGraphQLEnvelope<Repository>, repository: GitHubRepository
    ) throws
        -> [String: URL]
    {
        guard let repo = envelope.repository,
            repo.nameWithOwner?.lowercased() == repository.nameWithOwner.lowercased()
        else { throw ProviderResponseError.shape }
        var map: [String: URL] = [:]
        for node in repo.defaultBranchRef?.target?.history?.nodes ?? [] {
            guard let email = node.author?.email?.lowercased(), !email.isEmpty, email.utf8.count <= maximumEmail,
                map[email] == nil, let avatar = node.author?.user?.avatarUrl, let url = validated(avatar)
            else { continue }
            map[email] = url
        }
        return map
    }

    private static func isLogin(_ value: String) -> Bool {
        !value.isEmpty && value.count <= maximumLogin && !value.hasPrefix("-")
            && ProviderValidation.consists(value, of: loginCharacters)
    }

    struct Repository: Decodable, Sendable {
        struct Branch: Decodable, Sendable { var target: Target? }
        struct Target: Decodable, Sendable { var history: History? }
        struct History: Decodable, Sendable {
            @DecodedDefault<DefaultEmpty<Node>> var nodes: [Node]
        }
        struct Node: Decodable, Sendable { var author: Author? }
        struct Author: Decodable, Sendable {
            var email: String?
            var user: User?
        }
        struct User: Decodable, Sendable { var avatarUrl: String? }

        var nameWithOwner: String?
        var defaultBranchRef: Branch?
    }
}
