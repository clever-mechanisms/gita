import Foundation

/// Remote URLs for display and for the web-page links, from configuration only.
extension GitService {
    /// One remote's configured URL, sanitized like the snapshot's `remoteURL` (a read-only `git config`); nil when
    /// unset.
    public func remoteURL(named name: String) async -> String? {
        guard !name.isEmpty, !name.hasPrefix("-"), name.utf8.count <= 256, !GitInput.containsControlCharacters(name),
            let value = try? await configValue("remote." + name + ".url")
        else { return nil }
        return Self.singleLineDisplayURL(value)
    }

    /// The default remote's URL for this checkout (the current branch's remote, else `origin`), with `insteadOf`
    /// applied. `ls-remote --get-url` only reads configuration; it never contacts the remote. Nil without a remote.
    public func defaultRemoteURL() async -> String? {
        guard
            let result = try? await execute(
                ["ls-remote", "--get-url"], timeout: 10, outputLimit: 64 * 1_024, allowFailure: true),
            result.exitCode == 0
        else { return nil }
        return Self.singleLineDisplayURL(GitOutput.withoutTerminalLF(result.text))
    }

    /// Every remote's configured fetch URL by name (with `insteadOf` applied), from one read-only `git remote -v`;
    /// empty without remotes.
    public func remoteURLs() async -> [String: String] {
        guard
            let result = try? await execute(
                ["remote", "-v"], timeout: 10, outputLimit: 64 * 1_024, allowFailure: true),
            result.exitCode == 0
        else { return [:] }
        return Self.remoteURLs(fromRemoteList: result.text)
    }

    /// `<name>\t<url> (fetch)` lines as name → display URL (the first fetch URL of a name wins).
    static func remoteURLs(fromRemoteList text: String) -> [String: String] {
        var urls: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard line.hasSuffix(" (fetch)"), let tab = line.firstIndex(of: "\t") else { continue }
            let name = String(line[..<tab])
            guard !name.isEmpty, urls[name] == nil else { continue }
            let rest = line[line.index(after: tab)...].dropLast(" (fetch)".count)
            guard let url = singleLineDisplayURL(String(rest)) else { continue }
            urls[name] = url
        }
        return urls
    }

    private static func singleLineDisplayURL(_ value: String) -> String? {
        value.isEmpty || value.contains("\n") ? nil : RemoteURLPolicy.displayURL(value)
    }
}
