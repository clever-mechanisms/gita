import Foundation

/// The browser page behind a Git remote: `https://github.com/owner/repo` for `git@github.com:owner/repo.git`, and the
/// same for GitLab (subgroups included), Bitbucket, Codeberg, Azure DevOps and self-hosted servers. Pure string work,
/// no network. Only https pages come out (the app opens nothing else); credentials, queries and ssh ports are dropped.
public enum RemoteWebPage {
    public enum Host: Equatable, Sendable {
        case github, gitlab, bitbucket, codeberg, azure
        case other(String)
    }

    /// The repository's home page, or nil for a local path, `file://`, an unknown scheme or a path without owner/name.
    public static func repository(_ remote: String?) -> URL? {
        guard let remote = remote?.trimmingCharacters(in: .whitespacesAndNewlines), !remote.isEmpty,
            let (rawHost, port, path) = parse(remote)
        else { return nil }
        let host = canonicalHost(rawHost)
        let segments = path.split(separator: "/").map(String.init)
        // Azure DevOps ssh: `v3/org/project/repo` → `org/project/_git/repo`.
        if host == "ssh.dev.azure.com" || host == "vs-ssh.visualstudio.com" {
            guard segments.count == 4, segments[0] == "v3" else { return nil }
            return make(host: "dev.azure.com", port: nil, path: [segments[1], segments[2], "_git", segments[3]])
        }
        guard segments.count >= 2, !segments.contains(where: { $0 == "." || $0 == ".." || $0.hasPrefix("~") }) else {
            return nil
        }
        return make(host: host, port: port, path: segments)
    }

    /// The page for one branch where the host has a known layout; nil otherwise (callers fall back to `repository`).
    public static func branch(_ remote: String?, branch: String) -> URL? {
        guard !branch.isEmpty, let page = repository(remote),
            var parts = URLComponents(url: page, resolvingAgainstBaseURL: false)
        else { return nil }
        let encoded = branch.split(separator: "/", omittingEmptySubsequences: false)
            .map {
                $0.addingPercentEncoding(
                    withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#;")))
                    ?? String($0)
            }
            .joined(separator: "/")
        switch host(of: page) {
        case .github: parts.percentEncodedPath += "/tree/" + encoded
        case .gitlab: parts.percentEncodedPath += "/-/tree/" + encoded
        case .bitbucket: parts.percentEncodedPath += "/src/" + encoded
        case .codeberg: parts.percentEncodedPath += "/src/branch/" + encoded
        case .azure:
            parts.queryItems = [URLQueryItem(name: "version", value: "GB" + branch)]
        case .other: return nil
        }
        return parts.url
    }

    static func host(of page: URL) -> Host {
        let host = page.host?.lowercased() ?? ""
        switch host {
        case "github.com": return .github
        case "gitlab.com": return .gitlab
        case "bitbucket.org": return .bitbucket
        case "codeberg.org": return .codeberg
        case "dev.azure.com": return .azure
        default:
            if host.hasPrefix("gitlab.") { return .gitlab }
            if host.hasPrefix("github.") { return .github } // GitHub Enterprise Server
            return .other(host)
        }
    }

    /// Product names are not translated; a self-hosted server shows its host name.
    public static func hostName(of page: URL) -> String {
        switch host(of: page) {
        case .github: "GitHub"
        case .gitlab: "GitLab"
        case .bitbucket: "Bitbucket"
        case .codeberg: "Codeberg"
        case .azure: "Azure DevOps"
        case .other(let host): host
        }
    }

    // MARK: Parsing

    private static func parse(_ remote: String) -> (host: String, port: Int?, path: String)? {
        if remote.contains("://") {
            guard let parts = URLComponents(string: remote), let scheme = parts.scheme?.lowercased(),
                let host = parts.host, !host.isEmpty
            else { return nil }
            switch scheme {
            case "https", "http": return (host, scheme == "https" ? parts.port : nil, trimmed(parts.path))
            case "ssh", "git", "git+ssh", "ssh+git": return (host, nil, trimmed(parts.path))
            default: return nil // file://, ext:: and anything else
            }
        }
        // scp-like `[user@]host:path`; a local path has no colon before its first slash.
        guard !remote.hasPrefix("/"), !remote.hasPrefix("."), !remote.hasPrefix("~"),
            let colon = remote.firstIndex(of: ":")
        else { return nil }
        let authority = remote[..<colon]
        guard !authority.contains("/") else { return nil }
        let host = authority.split(separator: "@", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        guard !host.isEmpty, host.contains(".") else { return nil } // `alias:owner/repo` needs ~/.ssh/config to resolve
        return (host, nil, trimmed(String(remote[remote.index(after: colon)...])))
    }

    private static func trimmed(_ path: String) -> String {
        var value = path
        while value.hasSuffix("/") { value.removeLast() }
        if value.lowercased().hasSuffix(".git") { value.removeLast(4) }
        while value.hasPrefix("/") { value.removeFirst() }
        return value
    }

    /// `github.com-work` (a common ~/.ssh/config alias for a second account) → `github.com`.
    private static func canonicalHost(_ host: String) -> String {
        let lower = host.lowercased()
        for known in ["github.com", "gitlab.com", "bitbucket.org", "codeberg.org"]
        where lower.hasPrefix(known + "-") || lower.hasPrefix(known + "_") {
            return known
        }
        return lower
    }

    private static func make(host: String, port: Int?, path: [String]) -> URL? {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = host
        parts.port = port == 443 ? nil : port
        parts.path = "/" + path.joined(separator: "/")
        return parts.url
    }
}
