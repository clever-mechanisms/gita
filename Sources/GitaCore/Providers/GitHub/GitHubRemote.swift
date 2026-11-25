import Foundation

/// A remote that reaches a github.com repository, however it is spelled: `git@github.com:o/r.git`,
/// `https://login@github.com/o/r`, `ssh://git@ssh.github.com:443/o/r`, or an SSH host alias whose `HostName` is
/// github.com. The HTTPS user name, when it is a valid login, hints at the account the checkout was cloned with.
public struct GitHubRemote: Sendable, Hashable {
    let repository: GitHubRepository
    public let loginHint: GitHubLogin?
    /// The SSH host alias that resolved to github.com (e.g. `github-sqligrp`), nil for direct github.com remotes.
    public let sshAlias: String?

    /// Hosted identity, the same for every spelling of the remote.
    public var sourceID: String { repository.sourceID }
    /// `https://github.com/owner/name`.
    public var webURL: URL? { URL(string: "https://github.com/" + repository.nameWithOwner) }

    /// A remote on github.com itself (`git@github.com:o/r.git`, `https://github.com/o/r`,
    /// `ssh://git@ssh.github.com:443/o/r`); SSH host aliases need `GitHubRemoteResolver`.
    init?(address: RemoteAddress) {
        guard address.isGitHubHost, let repository = GitHubRepository(path: address.path) else { return nil }
        self.init(repository: repository, loginHint: address.loginHint, sshAlias: nil)
    }

    init(repository: GitHubRepository, loginHint: GitHubLogin?, sshAlias: String? = nil) {
        self.repository = repository
        self.loginHint = loginHint
        self.sshAlias = sshAlias
    }

    /// The lower-cased host of a remote URL or scp-like SSH target; nil when `remote` is not a remote address.
    public static func host(of remote: String) -> String? { RemoteAddress(remote)?.host }
}

/// Where a Git remote points, split into the parts the GitHub check needs. Pure string work; a password in the URL is
/// never kept.
struct RemoteAddress: Equatable {
    enum Transport: Equatable { case web, ssh }

    let transport: Transport
    let host: String
    let user: String?
    let path: String

    private static let webSchemes: Set<String> = ["https", "http", "git"]
    private static let sshSchemes: Set<String> = ["ssh", "git+ssh", "ssh+git"]

    init?(_ remote: String) {
        guard !remote.isEmpty, !remote.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        if remote.contains("://") {
            guard let url = URLComponents(string: remote), let scheme = url.scheme?.lowercased(),
                let host = url.host, !host.isEmpty, url.query == nil, url.fragment == nil
            else { return nil }
            if Self.webSchemes.contains(scheme) {
                transport = .web
            } else if Self.sshSchemes.contains(scheme) {
                transport = .ssh
            } else {
                return nil
            }
            self.host = host.lowercased()
            // A URL carrying a password (a token) gives no hint: nothing from it is used but host and path.
            user = url.password == nil ? url.user : nil
            path = Self.trimmed(url.path)
            return
        }
        // scp-like `[user@]host:path`; a local path has no colon before its first slash.
        guard !remote.hasPrefix("/"), !remote.hasPrefix("."), !remote.hasPrefix("~"),
            let colon = remote.firstIndex(of: ":")
        else { return nil }
        let authority = remote[..<colon]
        guard !authority.contains("/") else { return nil }
        let parts = authority.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        guard let host = parts.last, !host.isEmpty else { return nil }
        transport = .ssh
        self.host = host.lowercased()
        user = parts.count == 2 ? String(parts[0]) : nil
        path = Self.trimmed(String(remote[remote.index(after: colon)...]))
    }

    private static func trimmed(_ path: String) -> String {
        let value = String(path.drop(while: { $0 == "/" }))
        return value.hasSuffix(".git") ? String(value.dropLast(4)) : value
    }

    /// github.com itself, or GitHub's SSH-over-443 endpoint.
    var isGitHubHost: Bool { Self.isGitHub(host, transport: transport) }

    static func isGitHub(_ host: String, transport: Transport) -> Bool {
        host == "github.com" || transport == .ssh && host == "ssh.github.com"
    }

    /// An SSH host worth asking `ssh -G` about: a bare alias (`work`, `github-work`) or one that names GitHub
    /// (`github.com-work`). Known other forges are never asked.
    var mayBeGitHubAlias: Bool {
        transport == .ssh && !isGitHubHost && (!host.contains(".") || host.contains("github"))
            && SSHHostResolver.isValidAlias(host)
    }

    /// The HTTPS user name, when it is a GitHub login (never the SSH user, which is `git`).
    var loginHint: GitHubLogin? {
        transport == .web ? user.flatMap(GitHubLogin.init) : nil
    }
}

/// Turns a remote into a `GitHubRemote`, asking `ssh -G` (configuration only, no network) what an SSH alias
/// resolves to. Nothing is cached: `~/.ssh/config` can change at any time and the answer costs one local process.
public struct GitHubRemoteResolver: Sendable {
    let ssh: SSHHostResolver

    public init(runner: any CommandRunning = CommandRunner()) { ssh = SSHHostResolver(runner: runner) }

    public func resolve(_ remote: String?) async -> GitHubRemote? {
        guard let remote, let address = RemoteAddress(remote) else { return nil }
        if let direct = GitHubRemote(address: address) { return direct }
        guard address.mayBeGitHubAlias, let repository = GitHubRepository(path: address.path),
            let host = await ssh.hostName(of: address.host), RemoteAddress.isGitHub(host, transport: .ssh)
        else { return nil }
        return GitHubRemote(repository: repository, loginHint: nil, sshAlias: address.host)
    }
}

/// `ssh -G <alias>`'s `hostname`: what OpenSSH would connect to, read from configuration without connecting.
struct SSHHostResolver: Sendable {
    let runner: any CommandRunning

    static let executable = "/usr/bin/ssh"
    private static let timeout: TimeInterval = 3
    private static let outputLimit = 256 * 1_024
    private static let maximumAlias = 253
    private static let aliasCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")

    static func isValidAlias(_ alias: String) -> Bool {
        !alias.isEmpty && alias.utf8.count <= maximumAlias && !alias.hasPrefix("-")
            && ProviderValidation.consists(alias, of: aliasCharacters)
    }

    func hostName(of alias: String) async -> String? {
        guard Self.isValidAlias(alias) else { return nil }
        let request = CommandRequest(
            executable: Self.executable, arguments: ["-G", alias], timeout: Self.timeout,
            outputLimit: Self.outputLimit)
        guard let result = try? await runner.run(request), result.exitCode == 0 else { return nil }
        return Self.hostName(in: result.text)
    }

    static func hostName(in configuration: String) -> String? {
        for line in configuration.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", maxSplits: 1)
            if fields.count == 2, fields[0].lowercased() == "hostname" {
                return fields[1].trimmingCharacters(in: .whitespaces).lowercased()
            }
        }
        return nil
    }
}
