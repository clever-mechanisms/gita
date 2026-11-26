import Foundation

public struct QuickLookPreviewLoader: Sendable {
    private let runner: any CommandRunning
    private let maxLines: Int
    private let maxBytes: Int
    private let maxFiles: Int

    public init(
        runner: any CommandRunning = CommandRunner(), maxLines: Int = 200, maxBytes: Int = 32_768, maxFiles: Int = 50
    ) {
        self.runner = runner
        self.maxLines = max(0, maxLines)
        self.maxBytes = max(0, maxBytes)
        self.maxFiles = max(0, maxFiles)
    }

    public func load(_ target: QuickLookTarget) async throws -> QuickLookPreviewContent {
        try Task.checkCancellation()
        let git = GitService(root: target.root, runner: runner)
        switch target {
        case .commit(_, let sha, let hint):
            guard TeleportParser.sha(sha) != nil || GitParsers.isObjectID(sha) else { throw GitError.invalidReference }
            return try await revision(target, git, ref: sha, hint: hint, stash: false)
        case .stash(_, let ref, let message):
            guard GitInput.isStashReference(ref) else { throw GitError.invalidReference }
            return try await revision(target, git, ref: ref, hint: .init(subject: message), stash: true)
        case .changedFile(_, let path, let staged, let code, let sha):
            if let sha, TeleportParser.sha(sha) == nil && !GitParsers.isObjectID(sha) {
                throw GitError.invalidReference
            }
            let diff = try await git.diff(path: path, staged: staged, commit: sha)
            try Task.checkCancellation()
            let location = sha ?? (staged ? String(localized: "Staged") : String(localized: "Working tree"))
            var content = preview(target, title: path, subtitle: location, raw: diff)
            content.commitSHA = sha
            content.pills = [.init(title: Self.status(code), state: .neutral)]
            return content
        }
    }

    private func revision(
        _ target: QuickLookTarget, _ git: GitService, ref: String, hint: CommitHint?,
        stash: Bool
    ) async throws -> QuickLookPreviewContent {
        let metadata = try await git.execute([
            "show", "--no-patch", "--no-show-signature", "-z",
            "--format=" + GitArguments.commitFormat, ref, "--",
        ])
        guard let commit = GitParsers.commits(metadata.stdout).first else { throw GitError.invalidReference }
        try Task.checkCancellation()
        let revision = stash ? ref : commit.id
        let files = try await git.changedFiles(commit: revision)
        try Task.checkCancellation()
        let statArgs =
            stash
            ? ["stash", "show", "--include-untracked", "--shortstat"]
            : ["show", "--format=", "--no-show-signature", "--diff-merges=first-parent", "--shortstat"]
        let stat = try await git.execute(statArgs + GitArguments.safeDiff + [commit.id])
        try Task.checkCancellation()
        let diff = try await git.diff(path: nil, commit: revision)
        try Task.checkCancellation()
        var content = preview(
            target, title: hint?.subject ?? commit.subject,
            subtitle: stash ? ref : String(commit.id.prefix(12)), raw: diff)
        content.author = commit.author
        content.date = commit.date
        content.commitSHA = commit.id
        if stash, try await git.resolveCommit(ref) != content.commitSHA { throw GitError.invalidReference }
        try Task.checkCancellation()
        content.statSummary = ProviderValidation.nonempty(stat.text.trimmingCharacters(in: .whitespacesAndNewlines))
        content.files = files.prefix(maxFiles).map { .init(path: $0.path) }
        content.omittedFileCount = files.count - content.files.count
        content.pills = hint?.badges ?? []
        return content
    }

    private func preview(
        _ target: QuickLookTarget, title: String, subtitle: String, raw: String
    ) -> QuickLookPreviewContent {
        let excerpt = Self.truncateDiff(raw, maxLines: maxLines, maxBytes: maxBytes)
        let binary =
            raw.hasPrefix("Binary files ") || raw.contains("\nBinary files ") || raw.contains("\nGIT binary patch")
        return .init(target: target, title: title, subtitle: subtitle, diffExcerpt: excerpt, isBinary: binary)
    }

    /// Retain complete UTF-8 lines. Count each LF against the byte budget.
    public static func truncateDiff(_ raw: String, maxLines: Int, maxBytes: Int) -> QuickLookDiffExcerpt {
        let bytes = raw.utf8
        var start = bytes.startIndex
        var lines: [String] = []
        var count = 0
        var consumed = 0
        while start < bytes.endIndex {
            let end = bytes[start...].firstIndex(of: 10) ?? bytes.endIndex
            let next = end == bytes.endIndex ? end : bytes.index(after: end)
            consumed += bytes.distance(from: start, to: next)
            count += 1
            if count <= maxLines, consumed <= maxBytes {
                var line = bytes[start..<end]
                if line.last == 13 { line = line.dropLast() }
                lines.append(String(decoding: line, as: UTF8.self))
            }
            start = next
        }
        return .init(lines: lines, isTruncated: count > lines.count, totalLineCount: count, totalByteCount: consumed)
    }

    private static func status(_ code: FileChange.Code) -> String {
        switch code {
        case .added: String(localized: "Added")
        case .modified: String(localized: "Modified")
        case .typeChanged: String(localized: "Type changed")
        case .deleted: String(localized: "Deleted")
        case .renamed: String(localized: "Renamed")
        case .copied: String(localized: "Copied")
        case .unmerged: String(localized: "Conflict")
        case .untracked: String(localized: "Untracked")
        case .ignored: String(localized: "Ignored")
        case .unmodified: String(localized: "Unmodified")
        case .other(let status): String(localized: "Status \(status)")
        }
    }
}

extension CommitHint {
    public var badges: [QuickLookBadge] {
        var badges: [QuickLookBadge] = []
        if prTitle != nil || prState != nil {
            badges.append(.init(title: prTitle ?? String(localized: "Pull request"), state: prState ?? .neutral))
        }
        if let ciState {
            badges.append(.init(title: String(localized: "CI · \(ciState.localizedTitle)"), state: ciState))
        }
        return badges
    }
}
