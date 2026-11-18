import Foundation

extension GitService {
    /// Squash commit → the tip of the branch it squashed, for HEAD's line and the default branch's line.
    public func squashMerges() async throws -> [String: String] {
        var links: [String: String] = [:]
        var claimed = Set<String>()
        var seenLines = Set<String>()
        for line in try await mainLineNames() {
            guard let tip = try await commitOf(line), seenLines.insert(tip).inserted else { continue }
            let tips = try await unmergedTips(of: tip)
            guard !tips.isEmpty else { continue }
            let mainLine = try await mainLine(at: tip)
            guard !mainLine.isEmpty else { continue }
            for branchTip in tips where !claimed.contains(branchTip) {
                try Task.checkCancellation()
                guard let squash = try await squash(of: branchTip, on: mainLine, tip: tip, taken: Set(links.keys))
                else { continue }
                links[squash] = branchTip
                claimed.insert(branchTip)
            }
        }
        return links
    }

    /// HEAD, then the default branch (`origin/HEAD`, else `main` or `master`).
    private func mainLineNames() async throws -> [String] {
        let remoteDefault = try await execute(["symbolic-ref", "-q", "refs/remotes/origin/HEAD"], allowFailure: true)
        let fallback = try await execute(
            ["for-each-ref", "--format=%(refname)", "refs/heads/main", "refs/heads/master"], allowFailure: true)
        let name =
            remoteDefault.exitCode == 0
            ? remoteDefault.text.trimmingCharacters(in: .whitespacesAndNewlines)
            : fallback.text.split(separator: "\n").first.map(String.init)
        return ["HEAD"] + (name.map { $0.isEmpty ? [] : [$0] } ?? [])
    }

    private func commitOf(_ revision: String) async throws -> String? {
        let resolved = try await execute(["rev-parse", "--verify", "-q", revision + "^{commit}"], allowFailure: true)
        let tip = resolved.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return resolved.exitCode == 0 && !tip.isEmpty ? tip : nil
    }

    /// The most recently committed branches (local and remote, not remote HEADs) not merged into `tip`.
    private func unmergedTips(of tip: String) async throws -> [String] {
        let branches = try await execute(
            [
                "for-each-ref", "--no-merged=" + tip, "--sort=-committerdate", "--count=\(SquashMerges.branchLimit)",
                "--format=%(objectname) %(refname)", "refs/heads", "refs/remotes",
            ], allowFailure: true)
        return branches.text.split(separator: "\n").compactMap { row -> String? in
            let parts = row.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, !parts[1].hasSuffix("/HEAD") else { return nil }
            return String(parts[0])
        }
    }

    private func mainLine(at tip: String) async throws -> SquashMerges.MainLine {
        let log = try await execute(
            [
                "log", "--first-parent", "--no-merges", "--no-renames", "--raw", "--no-abbrev", "--format=%x01%H",
                "-\(SquashMerges.mainLineLimit)", tip, "--",
            ], outputLimit: 32 * 1_024 * 1_024, allowFailure: true)
        return SquashMerges.MainLine(log: log.text)
    }

    private func squash(
        of branchTip: String, on mainLine: SquashMerges.MainLine, tip: String, taken: Set<String>
    ) async throws -> String? {
        let base = try await execute(["merge-base", tip, branchTip], allowFailure: true)
        let fork = base.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard base.exitCode == 0, !fork.isEmpty else { return nil }
        let range = try await execute(
            ["diff-tree", "-r", "--no-renames", "--no-abbrev", fork, branchTip, "--"], allowFailure: true)
        guard range.exitCode == 0 else { return nil }
        return mainLine.squash(of: SquashMerges.entries(rawLines: Substring(range.text)), fork: fork, taken: taken)
    }
}
