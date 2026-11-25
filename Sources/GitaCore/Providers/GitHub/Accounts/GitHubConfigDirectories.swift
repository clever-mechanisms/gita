import Foundation

/// A validated sibling `gh` configuration profile folder name (e.g. `gh-sqligrp` inside `~/.config`).
/// Stores only the folder basename — never an arbitrary path or token — and resolves against `GitHubConfigDirectories`.
public struct GitHubConfigProfile: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let name: String

    private static let maximumLength = 100
    private static let characters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")

    public init?(_ name: String) {
        guard name.hasPrefix(GitHubConfigDirectories.prefix),
            name.count > GitHubConfigDirectories.prefix.count,
            name.utf8.count <= Self.maximumLength,
            !name.contains(".."),
            ProviderValidation.consists(name, of: Self.characters)
        else { return nil }
        self.name = name
    }

    public var description: String { name }

    /// The suffix after `gh-` (e.g. `work` for `gh-work`).
    public var suffix: String { String(name.dropFirst(GitHubConfigDirectories.prefix.count)) }

    /// Tilde-shortened display path for subtitles and terminal hints (e.g. `~/.config/gh-work`).
    public var displayPath: String { GitHubConfigDirectories.displayPath(for: self) }

    /// Whether an SSH host alias (e.g. `github-work`) names this profile's suffix (`work`).
    func matchesSSHAlias(_ alias: String?) -> Bool {
        guard let alias = alias?.lowercased() else { return false }
        let target = suffix.lowercased()
        return alias == target || alias.hasSuffix("-" + target) || alias.hasSuffix("_" + target)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.name.lowercased() < rhs.name.lowercased()
    }
}

/// Discovers and resolves sibling `gh` configuration directories (`$XDG_CONFIG_HOME/gh-*`, default `~/.config/gh-*`)
/// that contain a regular `hosts.yml` file. Never reads any file's contents; `gh` itself inspects each directory.
public struct GitHubConfigDirectories: Sendable {
    public static let maximumCount = 16
    static let prefix = "gh-"
    static let hostsFileName = "hosts.yml"

    public var discover: @Sendable () -> [GitHubConfigProfile]
    public var resolve: @Sendable (GitHubConfigProfile) -> String?

    public init(
        discover: @escaping @Sendable () -> [GitHubConfigProfile],
        resolve: @escaping @Sendable (GitHubConfigProfile) -> String?
    ) {
        self.discover = discover
        self.resolve = resolve
    }

    /// Scans `$XDG_CONFIG_HOME` (if set and absolute) or `$HOME/.config` for sibling `gh-*` folders.
    public static let system = Self(
        discover: { Self.discoverInEnvironment() },
        resolve: { Self.resolveInEnvironment($0) })

    /// No extra config directories: only `gh`'s default config directory is probed.
    public static let none = Self(discover: { [] }, resolve: { _ in nil })

    /// Validates an absolute directory path before it can reach `GH_CONFIG_DIR`.
    public static func isValidPath(_ path: String) -> Bool {
        !path.isEmpty && path.hasPrefix("/")
            && !path.contains(where: { $0 == "\0" || $0.isNewline })
    }

    /// Display path for a profile (e.g. `~/.config/gh-work` or `$XDG_CONFIG_HOME/gh-work`).
    public static func displayPath(
        for profile: GitHubConfigProfile,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> String {
        let full = baseDirectory(environment: environment, home: home)
            .appendingPathComponent(profile.name, isDirectory: true).standardizedFileURL.path
        guard !home.isEmpty else { return full }
        let homePrefix = home.hasSuffix("/") ? home : home + "/"
        guard full.hasPrefix(homePrefix) else { return full }
        return "~/" + full.dropFirst(homePrefix.count)
    }

    /// Sibling `gh-*` real directories inside `baseDirectory` that contain a regular `hosts.yml` file, sorted by name.
    public static func discover(in baseDirectory: URL) -> [GitHubConfigProfile] {
        let manager = FileManager.default
        guard
            let entries = try? manager.contentsOfDirectory(
                at: baseDirectory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
        else { return [] }
        var found: [GitHubConfigProfile] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let profile = GitHubConfigProfile(entry.lastPathComponent), isConfigDirectory(entry) else {
                continue
            }
            found.append(profile)
            if found.count >= maximumCount { break }
        }
        return found
    }

    private static func isConfigDirectory(_ entry: URL) -> Bool {
        guard let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
            values.isDirectory == true, values.isSymbolicLink != true
        else { return false }
        let hosts = entry.appendingPathComponent(hostsFileName)
        guard let hostsValues = try? hosts.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
            hostsValues.isRegularFile == true, hostsValues.isSymbolicLink != true
        else { return false }
        return true
    }

    static func discoverInEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> [GitHubConfigProfile] {
        discover(in: baseDirectory(environment: environment, home: home))
    }

    static func resolveInEnvironment(
        _ profile: GitHubConfigProfile,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> String? {
        let url = baseDirectory(environment: environment, home: home)
            .appendingPathComponent(profile.name, isDirectory: true)
        guard isConfigDirectory(url) else { return nil }
        let path = url.standardizedFileURL.path
        return isValidPath(path) ? path : nil
    }

    static func baseDirectory(environment: [String: String], home: String) -> URL {
        if let xdg = environment["XDG_CONFIG_HOME"], isValidPath(xdg) {
            return URL(fileURLWithPath: xdg, isDirectory: true)
        }
        return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".config", isDirectory: true)
    }
}
