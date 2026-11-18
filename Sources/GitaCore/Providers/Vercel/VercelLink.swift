import Foundation

/// The checkout whose `.vercel/project.json` links a hosted project, and that project's identity.
struct VercelLink: Sendable, Hashable {
    let root: URL
    /// `vercel:<org id>/<project id>`.
    let sourceID: String

    private static let prefix = "vercel:"

    /// The org and project ids of a source identity, when both are valid.
    static func parts(_ sourceID: String) -> (org: String, project: String)? {
        guard sourceID.hasPrefix(prefix) else { return nil }
        let parts = sourceID.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard parts.count == 2, ProviderValidation.isSlug(parts[0]), VercelIdentifiers.isProjectID(parts[1]) else {
            return nil
        }
        return (parts[0], parts[1])
    }

    static func sourceID(org: String, project: String) -> String { prefix + org + "/" + project }

    var parts: (org: String, project: String)? { Self.parts(sourceID) }
    /// The team id API reads need (`teamId=`), nil for a personal account.
    var teamID: String? { parts.flatMap { $0.org.hasPrefix("team_") ? $0.org : nil } }
}
