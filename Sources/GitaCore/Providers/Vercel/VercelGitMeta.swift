import Foundation

/// Git metadata Vercel records for a deployment. Values that are not strings are dropped, not fatal.
struct VercelGitMeta: Decodable, Sendable {
    private(set) var values: [String: String] = [:]

    private static let providers = ["github", "gitlab", "bitbucket", "git"]

    var commit: String? { first("CommitSha") }
    var branch: String? { first("CommitRef") }

    private func first(_ suffix: String) -> String? {
        Self.providers.lazy.compactMap { ProviderValidation.nonempty(values[$0 + suffix]) }.first
    }

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue _: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        for key in container.allKeys
        where key.stringValue.hasSuffix("CommitSha") || key.stringValue.hasSuffix("CommitRef") {
            if let value = try? container.decode(String.self, forKey: key) { values[key.stringValue] = value }
        }
    }
}
