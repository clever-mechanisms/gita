import Foundation

/// Recent branches visited in this checkout, read from the local HEAD reflog without locks or mutations.
extension GitService {
    /// Up to `limit` branch names most recently checked out in this working tree; empty when reflog is missing.
    public func recentBranches(limit: Int = 5) async -> [String] {
        guard limit > 0,
            let result = try? await execute(
                ["reflog", "--format=%gs", "-n", "200"], timeout: 10, outputLimit: 512 * 1_024,
                allowFailure: true),
            result.exitCode == 0
        else { return [] }
        return Self.parseRecentBranches(result.text, limit: limit)
    }

    /// Parses `git reflog --format=%gs` lines (`checkout: moving from <from> to <to>`) into unique branch names,
    /// most recent first. Commit SHAs from detached checkouts are omitted.
    static func parseRecentBranches(_ text: String, limit: Int = 5) -> [String] {
        guard limit > 0 else { return [] }
        let prefix = "checkout: moving from "
        var ordered: [String] = []
        var seen = Set<String>()
        var fallbackFroms: [String] = []
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
            guard line.hasPrefix(prefix) else { continue }
            let rest = line.dropFirst(prefix.count)
            guard let divider = rest.firstRange(of: " to ") else { continue }
            let from = String(rest[..<divider.lowerBound])
            let to = String(rest[divider.upperBound...])
            if !to.isEmpty, !GitParsers.isObjectID(to), seen.insert(to).inserted {
                ordered.append(to)
                if ordered.count >= limit { return ordered }
            }
            if !from.isEmpty, !GitParsers.isObjectID(from) { fallbackFroms.append(from) }
        }
        for branch in fallbackFroms where seen.insert(branch).inserted {
            ordered.append(branch)
            if ordered.count >= limit { break }
        }
        return ordered
    }
}
