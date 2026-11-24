import Foundation

/// Which repository URLs the app accepts for clone, fetch and remote configuration: HTTPS, SSH (URL or scp form)
/// and local paths, never credentials, queries, plain HTTP, helpers (`ext::`) or option-like values.
public enum RemoteURLPolicy {
    static let maximumLength = 32_768
    private static let allowedSchemes: Set<String> = ["https", "ssh", "file"]
    private static let host = #"(?:[A-Za-z0-9][A-Za-z0-9.-]*|\[[0-9A-Fa-f:]+\])"#
    private static let user = #"[A-Za-z0-9_][A-Za-z0-9_.-]*"#
    /// A colon is scp syntax only after a host (and optional user), never a helper name followed by `::`.
    /// Relative filesystem paths are intentionally refused as ambiguous.
    private static let scpForm = "^(?:" + user + "@)?" + host + #":[^:\s][^\r\n]*$"#

    /// The URL as Git should receive it (scheme lower-cased); throws `GitError.invalidRemote`.
    static func validate(_ remote: String) throws -> String {
        guard !remote.isEmpty, remote.utf8.count <= maximumLength, !remote.hasPrefix("-"),
            !GitInput.containsControlCharacters(remote)
        else { throw GitError.invalidRemote }
        if remote.hasPrefix("/") { return remote }
        if remote.contains("://") { return try validateURL(remote) }
        guard matches(remote, scpForm) else { throw GitError.invalidRemote }
        return remote
    }

    public static func isAccepted(_ remote: String) -> Bool { (try? validate(remote)) != nil }

    private static func validateURL(_ remote: String) throws -> String {
        guard let decoded = remote.removingPercentEncoding, !GitInput.containsControlCharacters(decoded),
            var parts = URLComponents(string: remote), let scheme = parts.scheme?.lowercased(),
            allowedSchemes.contains(scheme), hasPlainPath(parts)
        else { throw GitError.invalidRemote }
        parts.scheme = scheme
        guard authorityIsValid(parts, scheme: scheme), let value = parts.string else { throw GitError.invalidRemote }
        return value
    }

    /// An absolute, non-root path, a valid port, and nothing a credential or query could hide in.
    private static func hasPlainPath(_ parts: URLComponents) -> Bool {
        parts.password == nil && parts.query == nil && parts.fragment == nil && parts.path.hasPrefix("/")
            && parts.path != "/" && (parts.port.map { (1...65_535).contains($0) } ?? true)
    }

    private static func authorityIsValid(_ parts: URLComponents, scheme: String) -> Bool {
        switch scheme {
        case "file":
            return parts.user == nil && parts.port == nil && ["", "localhost"].contains(parts.host ?? "")
                && !parts.path.contains("\0")
        case "https":
            return parts.user == nil && parts.host.map(isHost) == true
        default:
            return parts.host.map(isHost) == true && (parts.user.map { matches($0, "^" + user + "$") } ?? true)
        }
    }

    private static func isHost(_ value: String) -> Bool { matches(value, "^" + host + "$") }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    /// A URL safe to show: no user (except for SSH, where it selects the account), password, query or fragment.
    public static func displayURL(_ value: String) -> String {
        if var components = URLComponents(string: value), let scheme = components.scheme?.lowercased(),
            ["http", "https", "ssh", "file"].contains(scheme)
        {
            if scheme != "ssh" { components.user = nil }
            components.password = nil
            components.query = nil
            components.fragment = nil
            return components.string ?? String(localized: "Unsupported repository URL")
        }
        return isAccepted(value) ? value : String(localized: "Unsupported repository URL")
    }
}
