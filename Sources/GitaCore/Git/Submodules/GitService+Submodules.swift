import Foundation

/// Parsed `.gitmodules` metadata for one submodule entry.
public struct GitmoduleConfigEntry: Sendable, Equatable, Hashable {
    public let name: String
    public let url: String?
    public let branch: String?

    public init(name: String, url: String?, branch: String?) {
        self.name = name
        self.url = url
        self.branch = branch
    }
}

/// Submodule inspection and explicit user-triggered mutations via `git submodule`.
extension GitService {
    /// Lists submodules with status, recorded SHA, URL, and configured branch.
    public func submodules() async throws -> [GitSubmodule] {
        let rootURL = try await repositoryRoot()
        let gitmodulesURL = rootURL.appendingPathComponent(".gitmodules")
        async let statusResult = execute(["submodule", "status"], timeout: 20, outputLimit: 2 * 1_024 * 1_024)
        async let configEntries = readGitmodulesConfig(at: gitmodulesURL)
        let (status, metadata) = try await (statusResult, configEntries)
        return Self.parseSubmoduleStatus(status.text, metadata: metadata)
    }

    /// Initializes and checks out submodules (`git submodule update --init`). Explicit user mutation only.
    public func initializeSubmodules(path: String? = nil, recursive: Bool = false) async throws {
        if let path { try GitInput.validatePath(path) }
        var args = GitArguments.transportAllowList + ["submodule", "update", "--init"]
        if recursive { args.append("--recursive") }
        if let path { args += ["--", path] }
        try await mutate(args, timeout: .untilIdle)
    }

    /// Updates initialized submodules (`git submodule update`). Explicit user mutation only.
    public func updateSubmodules(path: String? = nil, recursive: Bool = false) async throws {
        if let path { try GitInput.validatePath(path) }
        var args = GitArguments.transportAllowList + ["submodule", "update"]
        if recursive { args.append("--recursive") }
        if let path { args += ["--", path] }
        try await mutate(args, timeout: .untilIdle)
    }

    /// Synchronizes submodule remote URLs from `.gitmodules` (`git submodule sync`). Explicit user mutation only.
    public func syncSubmodules(path: String? = nil, recursive: Bool = false) async throws {
        if let path { try GitInput.validatePath(path) }
        var args = ["submodule", "sync"]
        if recursive { args.append("--recursive") }
        if let path { args += ["--", path] }
        try await mutate(args, timeout: .standard)
    }

    private func readGitmodulesConfig(at url: URL) async -> [String: GitmoduleConfigEntry] {
        guard FileManager.default.isReadableFile(atPath: url.path) else { return [:] }
        guard
            let result = try? await execute(
                ["config", "--file", ".gitmodules", "--null", "--list"],
                timeout: 10,
                outputLimit: 512 * 1_024,
                allowFailure: true
            ),
            result.exitCode == 0
        else { return [:] }
        return Self.parseGitmodulesConfig(result.stdout)
    }

    /// Parses `git config --file .gitmodules --null --list` output keyed by submodule path.
    public static func parseGitmodulesConfig(_ data: Data) -> [String: GitmoduleConfigEntry] {
        struct Builder {
            var path: String?
            var url: String?
            var branch: String?
        }
        var byName: [String: Builder] = [:]
        for record in GitOutput.nulFields(data) {
            guard !record.isEmpty else { continue }
            let parts = record.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0])
            let value = parts.count > 1 ? String(parts[1]) : ""
            guard let (name, field) = parseSubmoduleConfigKey(key) else { continue }
            var builder = byName[name] ?? Builder()
            switch field {
            case "path":
                builder.path = value
            case "url":
                builder.url = value
            case "branch":
                builder.branch = value
            default:
                break
            }
            byName[name] = builder
        }
        var byPath: [String: GitmoduleConfigEntry] = [:]
        for (name, builder) in byName {
            guard let path = builder.path, !path.isEmpty else { continue }
            byPath[path] = GitmoduleConfigEntry(name: name, url: builder.url, branch: builder.branch)
        }
        return byPath
    }

    /// Parses `git submodule status` lines combined with `.gitmodules` metadata.
    public static func parseSubmoduleStatus(
        _ output: String,
        metadata: [String: GitmoduleConfigEntry] = [:]
    ) -> [GitSubmodule] {
        let lines =
            output
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)

        var results: [GitSubmodule] = []
        results.reserveCapacity(lines.count)
        for line in lines {
            guard let parsed = parseStatusLine(line, metadata: metadata) else { continue }
            results.append(parsed)
        }
        return results.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func parseSubmoduleConfigKey(_ key: String) -> (name: String, field: String)? {
        guard key.hasPrefix("submodule.") else { return nil }
        let remainder = key.dropFirst("submodule.".count)
        guard let lastDot = remainder.lastIndex(of: ".") else { return nil }
        let name = String(remainder[..<lastDot])
        let field = String(remainder[remainder.index(after: lastDot)...]).lowercased()
        guard !name.isEmpty, !field.isEmpty else { return nil }
        return (name, field)
    }

    private static func parseStatusLine(
        _ line: String,
        metadata: [String: GitmoduleConfigEntry]
    ) -> GitSubmodule? {
        guard let prefix = line.first else { return nil }
        let rest = line.dropFirst()
        guard let firstSpace = rest.firstIndex(of: " ") else { return nil }
        let sha = String(rest[..<firstSpace])
        guard GitParsers.isObjectID(sha) else { return nil }
        let afterSHA = String(rest[rest.index(after: firstSpace)...])
        let (path, describe) = splitPathAndDescribe(afterSHA)
        guard !path.isEmpty else { return nil }
        let entry = metadata[path]
        return GitSubmodule(
            path: path,
            name: entry?.name ?? URL(fileURLWithPath: path).lastPathComponent,
            sha: sha,
            status: GitSubmoduleStatus(statusPrefix: prefix),
            url: entry?.url,
            branch: entry?.branch,
            describe: describe
        )
    }

    private static func splitPathAndDescribe(_ text: String) -> (path: String, describe: String?) {
        guard text.hasSuffix(")"), let marker = text.range(of: " (", options: .backwards) else {
            return (text, nil)
        }
        let path = String(text[..<marker.lowerBound])
        let start = text.index(marker.lowerBound, offsetBy: 2)
        let end = text.index(before: text.endIndex)
        let describe = start < end ? String(text[start..<end]) : nil
        return (path, describe)
    }
}
