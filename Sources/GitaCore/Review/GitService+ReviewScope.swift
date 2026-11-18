import Foundation

extension GitService {
    /// The review scope of a branch, remote branch or tag (`refs/…` full name or short name):
    /// - the default branch (`origin/HEAD`, else `main`/`master`) and its remote copy: unpushed commits, else incoming
    ///   ones, else the tip commit;
    /// - any other branch: its commits not on the default branch, else its tip commit.
    public func reviewScope(reference fullName: String) async throws -> ReviewScope {
        guard Self.isSafeReference(fullName) else { throw GitError.invalidReference }
        let short = Self.shortName(fullName)
        let tipID = try await commitID(fullName)
        let base = try await defaultBranch()
        let local = fullName.hasPrefix("refs/heads/") ? short : nil
        let worktree = try await checkout(of: local)

        // The default branch, local or its remote copy (Fork's "main...origin/main"): compare it with its upstream.
        let defaultLocal =
            local == base?.local ? local : (short == base?.compare && short != base?.local ? base?.local : nil)
        if let local = defaultLocal, let upstream = try await upstream(of: local) {
            let worktree = local == short ? worktree : try await checkout(of: local)
            let ahead = try await count(upstream + ".." + local)
            let behind = try await count(local + ".." + upstream)
            if ahead > 0 {
                return try await scope(
                    .unpushed(branch: local, upstream: upstream), range: upstream + "..." + local, commits: ahead,
                    checkout: worktree)
            }
            if behind > 0 {
                return try await scope(
                    .incoming(branch: local, upstream: upstream), range: local + "..." + upstream, commits: behind,
                    checkout: worktree)
            }
            return try await commitScope(tipID, checkout: worktree)
        }
        if let base, short != base.compare, short != base.local {
            let ahead = try await count(base.compare + ".." + short)
            if ahead > 0 {
                return try await scope(
                    .branch(tip: short, base: base.compare), range: base.compare + "..." + short, commits: ahead,
                    checkout: worktree)
            }
        }
        return try await commitScope(tipID, checkout: worktree)
    }

    /// The review scope of one commit.
    public func reviewScope(commit id: String) async throws -> ReviewScope {
        guard GitParsers.isObjectID(id) else { throw GitError.invalidReference }
        let head = try await execute(["rev-parse", "--verify", "--quiet", "HEAD"], allowFailure: true)
        let isHead = GitOutput.withoutTerminalLF(head.text) == id
        return try await commitScope(id, checkout: isHead ? try await repositoryRoot() : nil)
    }

    private func commitScope(_ id: String, checkout: URL?) async throws -> ReviewScope {
        let info = try await execute(["log", "-1", "--format=%P%x00%s", id])
        let fields = GitOutput.withoutTerminalLF(info.text).components(separatedBy: "\0")
        let parents = fields.first?.split(separator: " ").map(String.init) ?? []
        let subject = fields.count > 1 ? fields[1] : ""
        let range = parents.isEmpty ? nil : parents[0] + ".." + id
        let stats = try await diffStats(range ?? id, root: parents.isEmpty)
        let dirty = try await hasChanges(checkout)
        return ReviewScope(
            kind: .commit(id: id, subject: subject, isMerge: parents.count > 1), commits: 1, files: stats.files,
            insertions: stats.insertions, deletions: stats.deletions, checkout: checkout, includesWorkingTree: dirty)
    }

    private func scope(
        _ kind: ReviewScope.Kind, range: String, commits: Int, checkout: URL?
    ) async throws -> ReviewScope {
        let stats = try await diffStats(range, root: false)
        let dirty = try await hasChanges(checkout)
        return ReviewScope(
            kind: kind, commits: commits, files: stats.files, insertions: stats.insertions, deletions: stats.deletions,
            checkout: checkout, includesWorkingTree: dirty)
    }

    private func diffStats(_ range: String, root: Bool) async throws -> (files: Int, insertions: Int, deletions: Int) {
        let arguments =
            root ? ["show", "--numstat", "--format=", range] : ["diff", "--numstat", "--no-renames", range]
        let result = try await execute(arguments, timeout: 60, outputLimit: 32 * 1_024 * 1_024)
        var files = 0
        var insertions = 0
        var deletions = 0
        for line in result.text.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2)
            guard parts.count == 3 else { continue }
            files += 1
            insertions += Int(parts[0]) ?? 0
            deletions += Int(parts[1]) ?? 0
        }
        return (files, insertions, deletions)
    }

    private func hasChanges(_ checkout: URL?) async throws -> Bool {
        guard let checkout else { return false }
        let result = try await execute(
            ["-C", checkout.path, "status", "--porcelain", "--untracked-files=normal"], outputLimit: 64 * 1_024,
            allowFailure: true)
        return result.exitCode == 0 && !result.stdout.isEmpty
    }

    private func count(_ range: String) async throws -> Int {
        Int(GitOutput.withoutTerminalLF(try await execute(["rev-list", "--count", range], timeout: 60).text)) ?? 0
    }
    private func commitID(_ ref: String) async throws -> String {
        let sha = GitOutput.withoutTerminalLF(
            try await execute(["rev-parse", "--verify", "--end-of-options", ref + "^{commit}"]).text)
        guard GitParsers.isObjectID(sha) else { throw GitError.invalidReference }
        return sha
    }
    private static func shortName(_ ref: String) -> String {
        for prefix in ["refs/heads/", "refs/remotes/", "refs/tags/"] where ref.hasPrefix(prefix) {
            return String(ref.dropFirst(prefix.count))
        }
        return ref
    }
    private func upstream(of branch: String) async throws -> String? {
        let result = try await execute(
            ["rev-parse", "--abbrev-ref", "--symbolic-full-name", branch + "@{upstream}"], allowFailure: true)
        let name = GitOutput.withoutTerminalLF(result.text)
        return result.exitCode == 0 && !name.isEmpty ? name : nil
    }
    /// Where `branch` is checked out: the main checkout or a linked worktree.
    private func checkout(of branch: String?) async throws -> URL? {
        guard let branch else { return nil }
        let list = try await execute(["worktree", "list", "--porcelain"])
        var path: String?
        for line in list.text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                path = String(line.dropFirst(9))
            } else if line == "branch refs/heads/" + branch, let path {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return nil
    }
    /// `compare` is what other branches are measured against (`origin/main` when it exists, else `main`).
    private func defaultBranch() async throws -> (local: String, compare: String)? {
        let head = try await execute(
            ["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], allowFailure: true)
        let remote = GitOutput.withoutTerminalLF(head.text)
        if head.exitCode == 0, let slash = remote.firstIndex(of: "/") {
            let local = String(remote[remote.index(after: slash)...])
            return (local, remote)
        }
        for name in ["main", "master", "trunk", "develop"] {
            let local = try await execute(
                ["show-ref", "--verify", "--quiet", "refs/heads/" + name], allowFailure: true)
            if local.exitCode == 0 {
                let remote = try await execute(
                    ["show-ref", "--verify", "--quiet", "refs/remotes/origin/" + name], allowFailure: true)
                return (name, remote.exitCode == 0 ? "origin/" + name : name)
            }
        }
        return nil
    }
    static func isSafeReference(_ ref: String) -> Bool {
        !ref.isEmpty && !ref.hasPrefix("-") && !ref.contains("\0") && !ref.contains("\n") && !ref.contains("\r")
            && !ref.contains("..")
    }
}
