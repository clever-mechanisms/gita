import Foundation

/// When each branch last moved: what the branch switcher sorts by (most recently updated first).
extension GitService {
    /// Every local and remote-tracking branch's tip commit date, by full name; empty when the read fails.
    public func branchDates() async -> [String: Date] {
        guard
            let result = try? await execute(
                ["for-each-ref", "--format=%(refname)%00%(committerdate:unix)", "refs/heads", "refs/remotes"],
                timeout: 15, outputLimit: 4 << 20, allowFailure: true),
            result.exitCode == 0
        else { return [:] }
        return Self.branchDates(result.text)
    }

    /// `refname NUL unix-seconds` lines as full name → date; lines without a date are left out.
    static func branchDates(_ text: String) -> [String: Date] {
        var dates: [String: Date] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\0", omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, let seconds = TimeInterval(parts[1]) else { continue }
            dates[String(parts[0])] = Date(timeIntervalSince1970: seconds)
        }
        return dates
    }
}
