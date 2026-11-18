import Foundation

/// Checks for identifiers and URLs that come from provider responses. Anything that later becomes a command argument
/// or a link is validated here first.
enum ProviderValidation {
    static let slugCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
    static let hostLabelCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
    static let loginCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_[]")

    static let maximumSlugLength = 100
    static let maximumBranchLength = 255

    static func consists<Text: StringProtocol>(_ text: Text, of characters: CharacterSet) -> Bool {
        text.unicodeScalars.allSatisfy(characters.contains)
    }

    /// A provider slug or id: ASCII letters, digits, `-`, `_` and `.`, never an option or a path step.
    static func isSlug(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumSlugLength && !value.hasPrefix("-") && value != "."
            && value != ".." && consists(value, of: slugCharacters)
    }

    static func nonempty(_ text: String?) -> String? { text.flatMap { $0.isEmpty ? nil : $0 } }

    /// Non-empty text of at most `limit` characters (branch names from provider metadata).
    static func bounded(_ text: String?, limit: Int = maximumBranchLength) -> String? {
        nonempty(text).flatMap { $0.count <= limit ? $0 : nil }
    }

    /// An `https` URL with a host and no credentials; anything else is not opened.
    static func safeWebURL(_ text: String?) -> URL? {
        guard let text, let url = URL(string: text), url.scheme == "https", url.host != nil, url.user == nil,
            url.password == nil
        else { return nil }
        return url
    }

    static func httpsURL(host: String) -> URL? { safeWebURL("https://" + host) }
}
