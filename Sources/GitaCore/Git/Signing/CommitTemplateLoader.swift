import Darwin
import Foundation

/// A commit message template resolved from `commit.template` or the repository's `.gitmessage`.
public struct CommitTemplateResult: Sendable, Equatable, Hashable {
    public let content: String
    public let rawContent: String
    public let sourcePath: URL
    public let isConfiguredPath: Bool

    public init(content: String, rawContent: String, sourcePath: URL, isConfiguredPath: Bool) {
        self.content = content
        self.rawContent = rawContent
        self.sourcePath = sourcePath
        self.isConfiguredPath = isConfiguredPath
    }

    public var displayName: String { sourcePath.lastPathComponent }
}

/// Loads commit templates from Git's `commit.template` configuration or a repository-local `.gitmessage` file.
/// Rejects symlinks and non-regular files (FIFOs, devices) via `O_NOFOLLOW | O_NONBLOCK` + `fstat` and reads with a
/// hard byte cap so untrusted repositories cannot hang or leak files outside the working copy.
public enum CommitTemplateLoader {
    public static let maxTemplateBytes = 256 * 1_024

    /// Loads the active template for `service`, stripping comment lines safely. Returns nil when no template exists.
    public static func load(
        service: GitService,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) async -> CommitTemplateResult? {
        guard let root = try? await service.repositoryRoot() else { return nil }
        let settings = await service.commitTemplateSettings()
        guard
            let resolved = resolveTemplateURL(
                configuredPath: settings.path,
                repositoryRoot: root,
                homeDirectory: homeDirectory
            )
        else { return nil }
        return readTemplateSafely(
            at: resolved.url,
            isConfiguredPath: resolved.isConfigured,
            commentChar: settings.commentChar
        )
    }

    /// Resolves `configuredPath` (expanding `~` or relative paths against `repositoryRoot`), falling back to
    /// `<repositoryRoot>/.gitmessage` when `configuredPath` is unset.
    public static func resolveTemplateURL(
        configuredPath: String?,
        repositoryRoot: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> (url: URL, isConfigured: Bool)? {
        if let configured = configuredPath?.trimmingCharacters(in: .whitespacesAndNewlines), !configured.isEmpty {
            let candidate = expandPath(configured, repositoryRoot: repositoryRoot, homeDirectory: homeDirectory)
            return isRegularNonSymlinkFile(candidate) ? (candidate, true) : nil
        }
        let fallback = repositoryRoot.appendingPathComponent(".gitmessage")
        return isRegularNonSymlinkFile(fallback) ? (fallback, false) : nil
    }

    /// Strips comment lines (lines beginning with `commentChar`, defaulting to `#`) and trims leading/trailing
    /// blank lines while preserving internal paragraph breaks.
    public static func stripComments(_ raw: String, commentChar: String = "#") -> String {
        let prefix = effectiveCommentPrefix(commentChar)
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let kept = lines.filter { !$0.hasPrefix(prefix) }
        var start = 0
        while start < kept.count, kept[start].trimmingCharacters(in: .whitespaces).isEmpty {
            start += 1
        }
        var end = kept.count
        while end > start, kept[end - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            end -= 1
        }
        guard start < end else { return "" }
        return kept[start..<end].joined(separator: "\n")
    }

    private static func readTemplateSafely(
        at url: URL,
        isConfiguredPath: Bool,
        commentChar: String
    ) -> CommitTemplateResult? {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var statInfo = stat()
        guard Darwin.fstat(fd, &statInfo) == 0,
            (statInfo.st_mode & S_IFMT) == S_IFREG,
            statInfo.st_size >= 0,
            statInfo.st_size <= Int64(maxTemplateBytes)
        else { return nil }
        guard let data = try? handle.read(upToCount: maxTemplateBytes + 1),
            data.count <= maxTemplateBytes
        else { return nil }
        let raw = String(decoding: data, as: UTF8.self)
        let cleaned = stripComments(raw, commentChar: commentChar)
        return CommitTemplateResult(
            content: cleaned,
            rawContent: raw,
            sourcePath: url,
            isConfiguredPath: isConfiguredPath
        )
    }

    private static func isRegularNonSymlinkFile(_ url: URL) -> Bool {
        var statInfo = stat()
        guard Darwin.lstat(url.path, &statInfo) == 0 else { return false }
        return (statInfo.st_mode & S_IFMT) == S_IFREG
    }

    private static func expandPath(_ path: String, repositoryRoot: URL, homeDirectory: URL) -> URL {
        if path == "~" {
            return homeDirectory.standardizedFileURL
        }
        if path.hasPrefix("~/") {
            return homeDirectory.appendingPathComponent(String(path.dropFirst(2))).standardizedFileURL
        }
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return repositoryRoot.appendingPathComponent(path).standardizedFileURL
    }

    private static func effectiveCommentPrefix(_ commentChar: String) -> String {
        let trimmed = commentChar.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "auto" else { return "#" }
        return String(trimmed.prefix(1))
    }
}
