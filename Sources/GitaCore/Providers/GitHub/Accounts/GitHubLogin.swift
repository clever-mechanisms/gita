import Foundation

/// A GitHub account name as `gh` stores it: ASCII letters, digits, `-` and `_` (managed-user logins end in
/// `_shortcode`), never an option. Safe as a command argument; never a credential.
public struct GitHubLogin: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    public let value: String

    private static let maximumLength = 100
    private static let characters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")

    public init?(_ value: String) {
        guard !value.isEmpty, value.utf8.count <= Self.maximumLength, !value.hasPrefix("-"),
            ProviderValidation.consists(value, of: Self.characters)
        else { return nil }
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let login = Self(raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid login"))
        }
        self = login
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    public var description: String { value }

    /// GitHub logins are case-insensitive.
    func matches(_ other: String?) -> Bool { other?.lowercased() == value.lowercased() }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.value.lowercased() < rhs.value.lowercased() }
}

/// Which `gh` account a command runs as: the host's active account, or one named account through `gita-gh`.
public enum GitHubAccountUse: Sendable, Hashable {
    case active
    case named(GitHubLogin)
}
