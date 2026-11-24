import Foundation

/// A recent commit message authored by the current user, shown in the composer's recent-messages menu.
public struct RecentCommitMessage: Sendable, Equatable {
    public var subject: String
    public var body: String

    public init(subject: String, body: String = "") {
        self.subject = subject
        self.body = body
    }

    /// Combined subject and body (separated by a blank line when the body is non-empty).
    public var fullMessage: String {
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedBody.isEmpty ? subject : subject + "\n\n" + trimmedBody
    }
}

/// Read-only lookup of the user's recent commit messages in this repository.
extension GitService {
    private static let recentLogLimit = 30
    private static let recentMessageLimit = 10
    private static let recentOutputLimit = 256 * 1_024
    private static let recordSeparator = UInt8(0x1E)

    /// Up to `limit` unique recent commit subjects authored by the repository's configured `user.email`.
    public func recentCommitMessages(limit: Int = 10) async throws -> [RecentCommitMessage] {
        guard limit > 0, (try? await headCommit()) != nil else { return [] }
        let email = try? await effectiveConfigValue("user.email")
        var arguments = [
            "log", "-n", String(Self.recentLogLimit), "--fixed-strings", "--no-show-signature",
            "--format=%s%x00%b%x1e",
        ]
        if let email, !email.isEmpty, !email.contains("\0"), !email.contains("\n"), !email.contains("\r") {
            arguments.append("--author=<\(email)>")
        }
        arguments.append("--")
        let result = try await execute(arguments, timeout: 10, outputLimit: Self.recentOutputLimit)
        return Self.parseRecentMessages(result.stdout, limit: min(limit, Self.recentMessageLimit))
    }

    private func effectiveConfigValue(_ key: String) async throws -> String? {
        let result = try await execute(["config", "--null", "--get", key], allowFailure: true)
        guard result.exitCode == 0 else { return nil }
        let values = result.stdout.split(separator: GitOutput.nul, omittingEmptySubsequences: false)
        guard let first = values.first, !first.isEmpty else { return nil }
        return String(decoding: first, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parses `%s%x00%b%x1e` records, deduplicating by subject while keeping newest first.
    static func parseRecentMessages(_ data: Data, limit: Int = 10) -> [RecentCommitMessage] {
        guard limit > 0 else { return [] }
        var messages: [RecentCommitMessage] = []
        var seenSubjects: Set<String> = []
        for rawRecord in data.split(separator: Self.recordSeparator, omittingEmptySubsequences: true) {
            let record = rawRecord.first == GitOutput.lineFeed ? rawRecord.dropFirst() : rawRecord
            guard let nulIndex = record.firstIndex(of: GitOutput.nul) else { continue }
            let subject = String(decoding: record[..<nulIndex], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !subject.isEmpty, seenSubjects.insert(subject).inserted else { continue }
            let bodyStart = record.index(after: nulIndex)
            let body = String(decoding: record[bodyStart...], as: UTF8.self)
                .trimmingCharacters(in: .newlines)
            messages.append(RecentCommitMessage(subject: subject, body: body))
            if messages.count >= limit { break }
        }
        return messages
    }
}
