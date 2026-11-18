import CryptoKit
import Darwin
import Foundation

/// Reading and validating the plan an interactive rebase may rewrite. The review closes around every mutable input
/// (index, HEAD, branch, status, ancestry): they are read twice and must not change in between, and their digest is
/// the plan's identity that a later start must match.
extension GitService {
    struct RebaseReview {
        let plan: GitInteractiveRebasePlan
        let root: URL
        let directory: URL
    }

    /// Physical locations of the checkout, its Git directory and the common directory, with their identities.
    private struct RebaseLocation {
        let root: URL
        let directory: URL
        let common: URL
        let identities: (root: String, git: String, common: String)
        let sharedIndex: URL?
    }

    /// The mutable inputs a review is closed around.
    private struct RebaseInputs: Equatable {
        var status: Data
        var head: Data
        var branch: Data
        var branchExit: Int32
        var index: Data?
        var shared: Data?
        var ancestry: Data
    }

    private static let rebaseMinimumGit = (major: 2, minor: 45)
    private static let rebaseCommitLimit = 500
    private static let rebaseIndexLimit = 16 * 1_024 * 1_024
    private static let rebasePathLimit = 64 * 1_024
    private static let rebaseLogFormat = "%H%x00%P%x00%an%x00%ae%x00%at%x00%D%x00%s"

    func loadRebaseReview(after commitID: String) async throws -> RebaseReview {
        guard GitParsers.isObjectID(commitID) else { throw GitError.invalidReference }
        let options =
            try await localObjectOptions() + [
                "-c", "core.fsmonitor=false", "-c", "core.trustctime=true", "-c", "core.checkStat=default", "-c",
                "i18n.logOutputEncoding=UTF-8",
            ]
        try await requireRebaseCapableGit()
        let location = try await rebaseLocation(options: options)
        guard try await operationState() == nil else { throw GitError.operationActive }
        let inputs = try await rebaseInputs(location, options: options)
        let headID = GitOutput.withoutTerminalLF(String(decoding: inputs.head, as: UTF8.self))
        guard GitParsers.isObjectID(headID) else { throw GitError.invalidReference }
        let branch = try Self.rebaseBranch(inputs)
        let baseResult = try await execute(
            options + ["rev-parse", "--verify", commitID + "^{commit}"], timeout: 10, outputLimit: 4_096)
        guard GitOutput.withoutTerminalLF(baseResult.text) == commitID else { throw GitError.invalidReference }
        guard GitParsers.status(inputs.status).changes.isEmpty else { throw GitError.dirtyTrackedFiles }
        let entries = try await fullIndexEntries(options: options)
        let (base, baseData) = try await rebaseBaseCommit(commitID, options: options)
        let (commits, rangeData) = try await rebaseRange(from: commitID, to: headID, options: options)
        // Close the review around mutable inputs. Untracked files remain protected
        // by Git's own checkout checks and are never stashed or removed here.
        guard try await rebaseInputs(location, options: options) == inputs, try await operationState() == nil else {
            throw GitError.operationChanged
        }
        let identity = Self.rebaseIdentity(
            location: location, inputs: inputs, items: [entries, inputs.ancestry, baseData, rangeData])
        return RebaseReview(
            plan: GitInteractiveRebasePlan(
                base: base, headID: headID, branch: branch, commits: commits, identity: identity),
            root: location.root, directory: location.directory)
    }

    private func requireRebaseCapableGit() async throws {
        let version = try await execute(["--version"], timeout: 5, outputLimit: 4_096).text
        guard Self.isRebaseCapable(gitVersion: version) else {
            throw RebaseHistoryError.gitTooOld
        }
    }

    /// `git version 2.45.1 (Apple Git-…)` and later.
    static func isRebaseCapable(gitVersion version: String) -> Bool {
        let components =
            version.split(whereSeparator: { !$0.isNumber && $0 != "." }).first?.split(separator: ".").compactMap {
                Int($0)
            } ?? []
        guard components.count >= 2 else { return false }
        let minimum = rebaseMinimumGit
        return components[0] > minimum.major || (components[0] == minimum.major && components[1] >= minimum.minor)
    }

    private func rebaseLocation(options: [String]) async throws -> RebaseLocation {
        let root = try Self.physicalDirectory(try await repositoryRoot().path)
        let gitResult = try await execute(
            ["rev-parse", "--absolute-git-dir"], timeout: 5, outputLimit: Self.rebasePathLimit)
        let directory = try Self.physicalDirectory(GitOutput.withoutTerminalLF(gitResult.text))
        let commonResult = try await execute(
            ["rev-parse", "--path-format=absolute", "--git-common-dir"], timeout: 5, outputLimit: Self.rebasePathLimit)
        let common = try Self.physicalDirectory(GitOutput.withoutTerminalLF(commonResult.text))
        let identities = (
            try RebaseFiles.directoryIdentity(root), try RebaseFiles.directoryIdentity(directory),
            try RebaseFiles.directoryIdentity(common)
        )
        let sharedResult = try await execute(
            options + ["rev-parse", "--shared-index-path"], timeout: 5, outputLimit: Self.rebasePathLimit)
        let sharedPath = GitOutput.withoutTerminalLF(sharedResult.text)
        let sharedIndex =
            sharedPath.isEmpty ? nil : URL(fileURLWithPath: sharedPath, relativeTo: root).standardizedFileURL
        return RebaseLocation(
            root: root, directory: directory, common: common, identities: identities, sharedIndex: sharedIndex)
    }

    private func rebaseInputs(_ location: RebaseLocation, options: [String]) async throws -> RebaseInputs {
        let ancestry = try await rebaseAncestry(
            directory: location.directory, common: location.common, options: options)
        let index = try BoundedFile.contents(
            location.directory.appendingPathComponent("index"), limit: Self.rebaseIndexLimit)
        let shared = try location.sharedIndex.flatMap { try BoundedFile.contents($0, limit: Self.rebaseIndexLimit) }
        let head = try await execute(
            options + ["rev-parse", "--verify", "HEAD^{commit}"], timeout: 10, outputLimit: 4_096)
        let branch = try await execute(
            ["symbolic-ref", "--quiet", "HEAD"], timeout: 5, outputLimit: Self.rebasePathLimit, allowFailure: true)
        let status = try await execute(
            options + ["status", "--porcelain=v2", "-z", "--untracked-files=no", "--ignore-submodules=none"],
            timeout: 15, outputLimit: 4 * 1_024 * 1_024)
        return RebaseInputs(
            status: status.stdout, head: head.stdout, branch: branch.stdout, branchExit: branch.exitCode, index: index,
            shared: shared, ancestry: ancestry)
    }

    /// The local branch HEAD names, nil when detached; any other symbolic HEAD is refused.
    private static func rebaseBranch(_ inputs: RebaseInputs) throws -> String? {
        guard inputs.branchExit == 0 || inputs.branchExit == 1 else { throw GitError.invalidReference }
        guard inputs.branchExit == 0 else { return nil }
        let reference = GitOutput.withoutTerminalLF(String(decoding: inputs.branch, as: UTF8.self))
        guard reference.hasPrefix("refs/heads/") else {
            throw RebaseHistoryError.notLocalBranch
        }
        return String(reference.dropFirst("refs/heads/".count))
    }

    /// Sparse/assume-unchanged entries and submodules can hide tracked changes
    /// from the clean-worktree guard. This initial feature refuses those states.
    private func fullIndexEntries(options: [String]) async throws -> Data {
        let entries = try await execute(
            options + ["ls-files", "--stage", "-v", "-z"], timeout: 15, outputLimit: 8 * 1_024 * 1_024
        ).stdout
        guard Self.isFullIndex(entries) else {
            throw RebaseHistoryError.indexNotFull
        }
        return entries
    }

    /// Every `ls-files --stage -v -z` entry is a plain (`H`), stage-0, non-gitlink file.
    static func isFullIndex(_ entries: Data) -> Bool {
        entries.split(separator: 0).allSatisfy { entry in
            let header = entry.prefix { $0 != 9 }.split(separator: 32)
            return header.count == 4 && header[0] == Data("H".utf8) && header[3] == Data("0".utf8)
                && header[1] != Data(GitFileMode.submodule.rawValue.utf8)
        }
    }

    private func rebaseBaseCommit(_ commitID: String, options: [String]) async throws -> (GitCommit, Data) {
        let data = try await execute(
            options + [
                "log", "--no-show-signature", "--no-walk", "-z", "--format=" + Self.rebaseLogFormat, commitID, "--",
            ],
            timeout: 10, outputLimit: 128 * 1_024
        ).stdout
        guard let base = GitParsers.commits(data).first, base.id == commitID else { throw GitError.invalidReference }
        return (base, data)
    }

    private func rebaseRange(
        from commitID: String, to headID: String, options: [String]
    ) async throws -> ([GitCommit], Data) {
        let data = try await execute(
            options + [
                "log", "--topo-order", "--reverse", "--no-show-signature", "--no-decorate", "-z",
                "--format=" + Self.rebaseLogFormat, "--max-count=\(Self.rebaseCommitLimit + 1)",
                commitID + ".." + headID, "--",
            ], timeout: 20, outputLimit: 4 * 1_024 * 1_024
        ).stdout
        let commits = GitParsers.commits(data)
        try Self.validateRebaseRange(commits, base: commitID, head: headID)
        return (commits, data)
    }

    /// One to 500 commits, each the only child of the previous one, ending at HEAD.
    static func validateRebaseRange(_ commits: [GitCommit], base: String, head: String) throws {
        guard !commits.isEmpty else {
            throw RebaseHistoryError.noAncestor
        }
        guard commits.count <= rebaseCommitLimit else {
            throw RebaseHistoryError.rangeTooLong
        }
        var previous = base
        for commit in commits {
            guard commit.parents == [previous] else {
                throw RebaseHistoryError.nonlinearRange
            }
            previous = commit.id
        }
        guard previous == head else {
            throw RebaseHistoryError.notHeadAncestry
        }
    }

    private static func rebaseIdentity(location: RebaseLocation, inputs: RebaseInputs, items: [Data]) -> String {
        var digest = SHA256()
        let leading = [
            Data(location.root.path.utf8), Data(location.identities.root.utf8), Data(location.directory.path.utf8),
            Data(location.identities.git.utf8), Data(location.identities.common.utf8), inputs.head, inputs.branch,
            inputs.index ?? Data(), inputs.shared ?? Data(), inputs.status,
        ]
        for item in leading + items {
            digest.update(data: Data("\(item.count):".utf8))
            digest.update(data: item)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Rebase session files are opened one no-follow component at a time, so the
    /// Git directory must be its physical path. Foundation's resolvingSymlinksInPath
    /// is unsuitable: it rewrites /private/var, /private/tmp and /private/etc to their
    /// /var, /tmp and /etc symlinks, which that no-follow walk (correctly) refuses, and
    /// Git hands its editors the physical path. realpath(3) yields that physical path.
    static func physicalDirectory(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), !path.contains("\0"), let resolved = realpath(path, nil) else {
            throw RebasePlanError.planChanged
        }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    func rebaseAncestry(directory: URL, common: URL, options: [String]) async throws -> Data {
        // Replacements and grafts change the meaning of an immutable OID. Refuse
        // them explicitly rather than showing one tree and rewriting another.
        for (location, name) in [(directory, "BISECT_START"), (common, "shallow"), (common, "info/grafts")] {
            if let data = try BoundedFile.contents(location.appendingPathComponent(name)),
                !data.isEmpty || name == "BISECT_START"
            {
                throw RebaseHistoryError.incompleteHistory
            }
        }
        let replacements = try await execute(
            options + ["for-each-ref", "--format=%(refname)%00%(objectname)%00", "refs/replace/"], timeout: 10,
            outputLimit: 1_024 * 1_024
        ).stdout
        guard replacements.isEmpty else {
            throw RebaseHistoryError.replacementRefs
        }
        return replacements
    }
}
