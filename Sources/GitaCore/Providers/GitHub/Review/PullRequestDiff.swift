import Foundation

/// A pull request's changes as GitHub shows them (head against the merge base), one unified diff per file.
public struct PullRequestDiff: Sendable, Equatable {
    public var files: [PullRequestFileDiff]

    public init(files: [PullRequestFileDiff]) {
        self.files = files
    }
}

public struct PullRequestFileDiff: Identifiable, Sendable, Equatable {
    public var path: String
    /// The path before a rename; nil when the file kept its name.
    public var oldPath: String?
    public var additions: Int
    public var deletions: Int
    /// This file's part of the diff, from its `diff --git` line on.
    public var patch: String

    public var id: String { path }
}

/// Splits `gh pr diff` output at each `diff --git` line. Paths come from the `+++`/`---` lines (or the rename
/// headers), never from interpreting content; a file whose path cannot be read safely is dropped.
enum PullRequestDiffParser {
    static func parse(_ text: String) -> PullRequestDiff {
        var files: [PullRequestFileDiff] = []
        var current: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git "), !current.isEmpty {
                files.append(contentsOf: file(current))
                current = []
            }
            current.append(line)
        }
        files.append(contentsOf: file(current))
        return PullRequestDiff(files: files)
    }

    private static func file(_ lines: [Substring]) -> [PullRequestFileDiff] {
        guard let first = lines.first, first.hasPrefix("diff --git ") else { return [] }
        var oldPath: String?
        var newPath: String?
        var additions = 0
        var deletions = 0
        var inHunk = false
        for line in lines.dropFirst() {
            if inHunk {
                if line.hasPrefix("+") { additions += 1 } else if line.hasPrefix("-") { deletions += 1 }
                continue
            }
            if line.hasPrefix("@@") { inHunk = true }
            oldPath = oldPath ?? header(line, "--- a/") ?? header(line, "rename from ")
            newPath = newPath ?? header(line, "+++ b/") ?? header(line, "rename to ")
        }
        let path = newPath ?? oldPath ?? gitLinePath(first)
        guard let path, isSafe(path) else { return [] }
        var patch = lines.joined(separator: "\n")
        if !patch.hasSuffix("\n") { patch += "\n" }
        return [
            PullRequestFileDiff(
                path: path, oldPath: oldPath.flatMap { $0 == path ? nil : $0 }, additions: additions,
                deletions: deletions, patch: patch)
        ]
    }

    private static func header(_ line: Substring, _ prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        var value = String(line.dropFirst(prefix.count))
        if value.last == "\t" { value.removeLast() }
        return value
    }

    /// `diff --git a/x b/x` names a file with no `---`/`+++` lines (a mode change or an empty file); only an
    /// unambiguous line with the same path on both sides is read.
    private static func gitLinePath(_ line: Substring) -> String? {
        let rest = line.dropFirst("diff --git a/".count)
        let half = (rest.count - " b/".count) / 2
        guard line.hasPrefix("diff --git a/"), half > 0 else { return nil }
        let old = rest.prefix(half)
        guard rest.dropFirst(half).hasPrefix(" b/"), rest.dropFirst(half + 3) == old else { return nil }
        return String(old)
    }

    private static func isSafe(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\0") && !path.hasPrefix("\"")
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != ".." }
    }
}
