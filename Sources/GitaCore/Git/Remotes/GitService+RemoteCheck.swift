import Foundation

/// Identifies a branch on a specific remote (`origin`, `main`).
public struct RemoteBranchKey: Hashable, Sendable {
    public var remote: String
    /// Branch name without `refs/heads/` or `refs/remotes/<remote>/`.
    public var branch: String

    public init(remote: String, branch: String) {
        self.remote = remote
        self.branch = branch
    }
}

/// The local remote-tracking tip compared to the remote's current tip from `ls-remote`.
public struct RemoteTip: Equatable, Sendable {
    public var localOID: String?
    public var remoteOID: String

    public init(localOID: String?, remoteOID: String) {
        self.localOID = localOID
        self.remoteOID = remoteOID
    }
}

/// Differences observed by a read-only Tier 1 `ls-remote` check without downloading objects.
public struct RemoteDelta: Equatable, Sendable {
    public var moved: [RemoteBranchKey: RemoteTip]
    public var gone: Set<RemoteBranchKey>
    public var currentUpstreamMoved: Bool
    public var currentUpstreamKey: RemoteBranchKey?
    public var checkedAt: Date

    public var movedCount: Int { moved.count }
    public var isEmpty: Bool { moved.isEmpty && gone.isEmpty }
    public var movedRemotes: [String] { Array(Set(moved.keys.map(\.remote))).sorted() }

    public init(
        moved: [RemoteBranchKey: RemoteTip] = [:], gone: Set<RemoteBranchKey> = [],
        currentUpstreamMoved: Bool = false, currentUpstreamKey: RemoteBranchKey? = nil, checkedAt: Date = Date()
    ) {
        self.moved = moved
        self.gone = gone
        self.currentUpstreamMoved = currentUpstreamMoved
        self.currentUpstreamKey = currentUpstreamKey
        self.checkedAt = checkedAt
    }

    public mutating func clearing(remotes: [String], checkedAt: Date) {
        let fetched = Set(remotes)
        moved = moved.filter { !fetched.contains($0.key.remote) }
        updateCurrentUpstreamMoved()
        self.checkedAt = checkedAt
    }

    public mutating func reconciling(references: [GitReference]) {
        let remoteCommits = Dictionary(
            references.lazy.filter { $0.kind == .remote }.map { ($0.name, $0.commit) },
            uniquingKeysWith: { first, _ in first })
        moved = moved.filter { key, tip in
            remoteCommits[key.remote + "/" + key.branch] != tip.remoteOID
        }
        gone = gone.filter { key in
            remoteCommits[key.remote + "/" + key.branch] != nil
        }
        updateCurrentUpstreamMoved()
    }

    private mutating func updateCurrentUpstreamMoved() {
        guard currentUpstreamMoved else {
            currentUpstreamKey = nil
            return
        }
        if let currentUpstreamKey {
            currentUpstreamMoved = moved[currentUpstreamKey] != nil
        } else if moved.isEmpty {
            currentUpstreamMoved = false
        }
        if !currentUpstreamMoved { currentUpstreamKey = nil }
    }
}

/// Why a background remote check or auto-fetch could not finish.
public enum RemoteCheckFailure: Equatable, Sendable {
    case unreachable
    case authenticationRequired
    case timedOut
    case unsupportedURL
}

/// Error produced by background remote check and auto-fetch operations.
public struct RemoteCheckError: Error, LocalizedError, Equatable, Sendable {
    public let failure: RemoteCheckFailure
    public let remote: String?
    public let detail: String

    public init(failure: RemoteCheckFailure, remote: String? = nil, detail: String = "") {
        self.failure = failure
        self.remote = remote
        self.detail = detail
    }

    public var errorDescription: String? {
        if !detail.isEmpty { return detail }
        switch failure {
        case .unreachable: return String(localized: "Remote is unreachable.")
        case .authenticationRequired: return String(localized: "Authentication is required for this remote.")
        case .timedOut: return String(localized: "Remote check timed out.")
        case .unsupportedURL: return String(localized: "Remote URL is not supported for background checks.")
        }
    }
}

/// Tier 1 read-only remote awareness (`ls-remote`) and Tier 2 opt-in atomic remote-tracking auto-fetch.
extension GitService {
    static let maxRemoteCheckPatterns = 64

    private static let authIndicators = [
        "authentication failed", "could not read username", "could not read password",
        "terminal prompts disabled", "permission denied (publickey", "host key verification failed",
        "invalid username or password", "authorization failed", "access denied",
        "user cancelled", "returned error: 401", "returned error: 403", "http 401", "http 403",
    ]

    /// Read-only Tier 1 check of `remote` against `upstreams` and local remote-tracking `references`.
    public func checkRemote(
        _ remote: String, upstreams: [String: GitBranchUpstream], references: [GitReference],
        currentBranch: String?, now: Date = Date()
    ) async throws -> RemoteDelta {
        try validateRemoteCheckName(remote)
        try await requireAcceptedRemoteURLs(remote)
        let tracked = await trackedRemoteBranches(for: remote, upstreams: upstreams, references: references)
        guard !tracked.isEmpty else { return RemoteDelta(checkedAt: now) }
        let patterns =
            tracked.count <= Self.maxRemoteCheckPatterns
            ? tracked.sorted().map { GitReference.Kind.branch.prefix + $0 } : []
        let arguments =
            GitArguments.transportAllowList + GitArguments.noHooks
            + ["ls-remote", "--heads", "--quiet", "--", remote] + patterns
        let result = try await runBackgroundGit(arguments, remote: remote, timeout: .standard)
        let remoteTips = Self.parseLSRemote(result.text)
        let tracking = RemoteTrackingState(
            upstreams: upstreams, references: references, currentBranch: currentBranch)
        return Self.buildDelta(remote: remote, tracked: tracked, remoteTips: remoteTips, local: tracking, now: now)
    }

    /// Tier 2 opt-in atomic background fetch of `remote` (`refs/remotes/*` only, never pruning or writing
    /// `FETCH_HEAD`).
    public func backgroundFetch(remote: String) async throws {
        try validateRemoteCheckName(remote)
        try await requireAcceptedRemoteURLs(remote)
        try await mutate { service in
            let arguments =
                GitArguments.transportAllowList + GitArguments.noHooks + [
                    "fetch", "--atomic", "--no-tags", "--no-recurse-submodules", "--no-prune", "--no-prune-tags",
                    "--no-write-fetch-head", "--no-auto-maintenance", "--no-write-commit-graph", "--quiet", "--refmap=",
                    "--",
                    remote, "+refs/heads/*:refs/remotes/\(remote)/*",
                ]
            _ = try await service.runBackgroundGit(arguments, remote: remote, timeout: .untilIdle, mutation: true)
        }
    }

    static func parseLSRemote(_ text: String) -> [String: String] {
        var tips: [String: String] = [:]
        for line in GitOutput.lines(text) {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let oid = String(line[..<tab])
            let ref = String(line[line.index(after: tab)...])
            guard GitParsers.isObjectID(oid), !ref.hasSuffix("^{}"),
                let branch = ref.dropPrefix(GitReference.Kind.branch.prefix)
            else { continue }
            tips[branch] = oid
        }
        return tips
    }

    static func classifyFailure(stderr: String) -> RemoteCheckFailure {
        let lowered = stderr.lowercased()
        return authIndicators.contains(where: lowered.contains) ? .authenticationRequired : .unreachable
    }

    struct RemoteTrackingState: Sendable {
        let upstreams: [String: GitBranchUpstream]
        let references: [GitReference]
        let currentBranch: String?
    }

    static func buildDelta(
        remote: String, tracked: Set<String>, remoteTips: [String: String], local: RemoteTrackingState, now: Date
    ) -> RemoteDelta {
        var localTips: [String: String] = [:]
        for reference in local.references where reference.kind == .remote {
            if let branch = reference.name.dropPrefix(remote + "/") { localTips[branch] = reference.commit }
        }
        var moved: [RemoteBranchKey: RemoteTip] = [:]
        var gone: Set<RemoteBranchKey> = []
        for branch in tracked {
            let key = RemoteBranchKey(remote: remote, branch: branch)
            let localOID = localTips[branch]
            if let remoteOID = remoteTips[branch] {
                if localOID != remoteOID { moved[key] = RemoteTip(localOID: localOID, remoteOID: remoteOID) }
            } else if localOID != nil {
                gone.insert(key)
            }
        }
        let upstream = local.currentBranch.flatMap { local.upstreams[$0] }
        let upstreamKey = upstream.map { RemoteBranchKey(remote: $0.remote, branch: $0.branch) }
        let currentMoved =
            upstreamKey.map { $0.remote == remote && moved[$0] != nil }
            ?? false
        return RemoteDelta(
            moved: moved, gone: gone, currentUpstreamMoved: currentMoved,
            currentUpstreamKey: currentMoved ? upstreamKey : nil, checkedAt: now)
    }

    private func trackedRemoteBranches(
        for remote: String, upstreams: [String: GitBranchUpstream], references: [GitReference]
    ) async -> Set<String> {
        var tracked = Set(upstreams.values.filter { $0.remote == remote }.map(\.branch))
        if let head = try? await execute(
            ["symbolic-ref", "--quiet", GitReference.Kind.remote.prefix + remote + "/HEAD"],
            timeout: 10, outputLimit: 4_096, allowFailure: true),
            head.exitCode == 0,
            let branch = GitOutput.withoutTerminalLF(head.text)
                .dropPrefix(GitReference.Kind.remote.prefix + remote + "/")
        {
            tracked.insert(branch)
        }
        if tracked.isEmpty {
            for reference in references where reference.kind == .remote {
                if let branch = reference.name.dropPrefix(remote + "/"), branch != "HEAD" {
                    tracked.insert(branch)
                }
            }
        }
        return tracked
    }

    private func validateRemoteCheckName(_ remote: String) throws {
        guard !remote.isEmpty, !remote.hasPrefix("-"), remote.utf8.count <= 256,
            !GitInput.containsControlCharacters(remote)
        else {
            throw RemoteCheckError(
                failure: .unreachable, remote: remote, detail: String(localized: "Invalid remote name."))
        }
    }

    private func requireAcceptedRemoteURLs(_ remote: String) async throws {
        let raw = try await execute(
            ["config", "--null", "--get-all", "remote." + remote + ".url"],
            timeout: 10, outputLimit: 64 * 1_024, allowFailure: true)
        let resolved = try await execute(
            ["remote", "get-url", "--all", "--", remote],
            timeout: 10, outputLimit: 64 * 1_024, allowFailure: true)
        let rawURLs = raw.exitCode == 0 ? GitOutput.nulFields(raw.stdout).filter { !$0.isEmpty } : []
        let resolvedURLs = resolved.exitCode == 0 ? GitOutput.lines(resolved.text) : []
        let allURLs = rawURLs + resolvedURLs
        guard !allURLs.isEmpty else {
            throw RemoteCheckError(
                failure: .unreachable, remote: remote,
                detail: String(localized: "Remote '\(remote)' has no configured URL."))
        }
        guard allURLs.allSatisfy(RemoteURLPolicy.isAccepted) else {
            throw RemoteCheckError(
                failure: .unsupportedURL, remote: remote,
                detail: String(localized: "Remote URL is refused by policy (plain HTTP is not allowed)."))
        }
    }

    private func runBackgroundGit(
        _ arguments: [String], remote: String, timeout: GitTimeout, mutation: Bool = false
    ) async throws -> CommandResult {
        var request = try await gitRequest(
            arguments, outputLimit: CommandRequest.defaultOutputLimit, mutation: mutation)
        request.environment = .gitBackground
        timeout.apply(to: &request)
        let result: CommandResult
        do {
            result = try await runner.run(request)
        } catch CommandError.timedOut {
            throw RemoteCheckError(
                failure: .timedOut, remote: remote, detail: CommandError.timedOut.localizedDescription)
        } catch let error as CommandError {
            throw RemoteCheckError(failure: .unreachable, remote: remote, detail: error.localizedDescription)
        }
        guard result.exitCode == 0 else {
            let message = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw RemoteCheckError(
                failure: Self.classifyFailure(stderr: message), remote: remote,
                detail: Self.redactingCredentials(message))
        }
        return result
    }
}
