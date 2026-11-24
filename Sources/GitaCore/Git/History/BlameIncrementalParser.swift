import Foundation

/// Stateful incremental parser for `git blame --porcelain --incremental` output.
struct BlameIncrementalParser: Sendable {
    private struct PendingHunk {
        var commitID: String
        var finalLine: Int
        var lineCount: Int
        var author = ""
        var email = ""
        var authorTime: TimeInterval?
        var summary = ""
        var previousCommit: String?
        var previousPath: String?
        var isBoundary = false
        var hasMetadata = false
    }

    private var buffer = Data()
    private var current: PendingHunk?

    mutating func feed(_ chunk: Data) -> (hunks: [BlameHunk], commits: [String: BlameCommitInfo]) {
        if !chunk.isEmpty { buffer.append(chunk) }
        var hunks: [BlameHunk] = []
        var commits: [String: BlameCommitInfo] = [:]
        while let newline = buffer.firstIndex(of: GitOutput.lineFeed) {
            let lineData = buffer[..<newline]
            buffer = Data(buffer[buffer.index(after: newline)...])
            let rawLine = String(decoding: lineData, as: UTF8.self)
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if let completed = consume(line: line) {
                hunks.append(completed.hunk)
                if let info = completed.commit { commits[info.id] = info }
            }
        }
        return (hunks, commits)
    }

    mutating func finish() -> (hunks: [BlameHunk], commits: [String: BlameCommitInfo]) {
        guard !buffer.isEmpty else { return ([], [:]) }
        return feed(Data([GitOutput.lineFeed]))
    }

    private mutating func consume(line: String) -> (hunk: BlameHunk, commit: BlameCommitInfo?)? {
        guard !line.isEmpty else { return nil }
        if current == nil {
            current = Self.parseHeader(line)
            return nil
        }
        if line.hasPrefix("filename ") {
            guard let completed = current else { return nil }
            current = nil
            return Self.finalize(completed)
        }
        if current != nil { applyField(line) }
        return nil
    }

    private mutating func applyField(_ line: String) {
        if line == "boundary" {
            current?.isBoundary = true
            return
        }
        if let value = Self.suffix(of: line, prefix: "author ") {
            current?.author = value
            current?.hasMetadata = true
        } else if let value = Self.suffix(of: line, prefix: "author-mail ") {
            current?.email = Self.trimmedEmail(value)
        } else if let value = Self.suffix(of: line, prefix: "author-time "), let seconds = TimeInterval(value) {
            current?.authorTime = seconds
            current?.hasMetadata = true
        } else if let value = Self.suffix(of: line, prefix: "summary ") {
            current?.summary = value
            current?.hasMetadata = true
        } else if let value = Self.suffix(of: line, prefix: "previous ") {
            let parts = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 {
                current?.previousCommit = String(parts[0])
                current?.previousPath = String(parts[1])
            }
        }
    }

    private static func parseHeader(_ line: String) -> PendingHunk? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 4 else { return nil }
        let sha = String(parts[0])
        guard GitParsers.isObjectID(sha),
            Int(parts[1]) != nil,
            let final = Int(parts[2]),
            let count = Int(parts[3])
        else { return nil }
        return PendingHunk(commitID: sha, finalLine: final, lineCount: count)
    }

    private static func finalize(
        _ pending: PendingHunk
    ) -> (hunk: BlameHunk, commit: BlameCommitInfo?) {
        let hunk = BlameHunk(
            commitID: pending.commitID, finalLine: pending.finalLine,
            lineCount: pending.lineCount, previousCommit: pending.previousCommit, previousPath: pending.previousPath)
        guard pending.hasMetadata else { return (hunk, nil) }
        let isUncommitted = pending.commitID.allSatisfy { $0 == "0" }
        let info = BlameCommitInfo(
            id: pending.commitID, author: pending.author, email: pending.email,
            date: Date(timeIntervalSince1970: pending.authorTime ?? 0), summary: pending.summary,
            isBoundary: pending.isBoundary, isUncommitted: isUncommitted)
        return (hunk, info)
    }

    private static func suffix(of line: String, prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count))
    }

    private static func trimmedEmail(_ raw: String) -> String {
        var result = raw
        if result.hasPrefix("<") { result.removeFirst() }
        if result.hasSuffix(">") { result.removeLast() }
        return result
    }
}
