import Foundation

/// The on-demand review of one branch, remote branch or tag, separate from the periodic history snapshot.
extension GitService {
    /// The state a branch's review adds: its upstream and the merge basis for a safe delete.
    private struct BranchReview {
        var upstream: GitReferenceUpstream?
        var mergeTarget: String?
        var mergeCommit: String?
        var ancestry = MergeAncestry.unchecked
    }

    /// Whether the branch is merged into its delete target; unchecked when there is no target to check.
    private enum MergeAncestry {
        case unchecked, merged, unmerged

        var status: GitMergeStatus {
            switch self {
            case .unchecked: .unknown
            case .merged: .merged
            case .unmerged: .notMerged
            }
        }
    }

    /// HEAD as one review sees it.
    private struct HeadState {
        var commit: String?
        var symbolic: CommandResult
        var currentName: String? { symbolic.exitCode == 0 ? GitOutput.line(symbolic.stdout) : nil }
    }

    /// Read only the selected reference and the state relevant to its review.
    public func referenceDetails(fullName: String) async throws -> GitReferenceDetails {
        let kind = try await validateFullReference(fullName)
        let record = try await referenceRecord(fullName)
        guard record.symbolicTarget.isEmpty, kind == .tag || record.objectType == "commit" else {
            throw GitError.invalidReference
        }
        let root = try await repositoryRoot()
        let directories = try await referenceDirectories()
        let head = try await headState()
        let peeled = try await referenceCommand(
            ["rev-parse", "--verify", "--quiet", "--end-of-options", fullName + "^{commit}"], allowFailure: true)
        let commitID = peeled.exitCode == 0 ? GitOutput.line(peeled.stdout) : nil
        guard commitID.map(GitParsers.isObjectID) ?? true else { throw GitError.invalidReference }

        var identity = Fingerprint()
        identity.add("root", root.path)
        identity.add("worktree-directory", directories.worktree.path)
        identity.add("common-directory", directories.common.path)
        identity.add("reference", record.bytes)
        identity.add("HEAD", head.symbolic.exitCode == 0 ? head.symbolic.stdout : nil)
        identity.add("HEAD-commit", head.commit ?? "")
        identity.add("operation", try await operationState()?.identity ?? "")
        identity.add("bisect", try BoundedFile.contents(directories.worktree.appendingPathComponent("BISECT_START")))
        let shortName = String(fullName.dropFirst(kind.prefix.count))
        var branch = BranchReview()
        if kind == .branch {
            branch = try await branchReview(
                shortName, record: record, commitID: commitID, head: head.commit, common: directories.common,
                identity: &identity)
        } else if kind == .remote {
            identity.add("fetch-mappings", try await referenceFetchMappings(fullName))
        }
        let occupancy =
            kind == .branch
            ? try await ReferenceOccupancy.read(fullName, directories: directories, service: self)
            : ReferenceOccupancy()
        identity.add("occupancy", occupancy.identity)
        // Reject a ref that moved while its associated metadata was being read.
        guard try await referenceRecord(fullName).bytes == record.bytes else { throw GitError.staleReference }
        let reference = GitReference(
            name: shortName, fullName: fullName, commit: commitID ?? record.objectID, kind: kind,
            isCurrent: head.currentName.map { GitOutput.same($0, fullName) } ?? false)
        return GitReferenceDetails(
            root: root, reference: reference, objectID: record.objectID, objectType: record.objectType,
            commitID: commitID, upstream: branch.upstream, worktreePaths: occupancy.paths,
            deleteMergeTarget: branch.mergeTarget, deleteMergeCommitID: branch.mergeCommit,
            mergeStatus: branch.ancestry.status,
            fingerprint: identity.hex)
    }

    private func headState() async throws -> HeadState {
        async let headResult = referenceCommand(
            ["rev-parse", "--verify", "--quiet", "--end-of-options", "HEAD^{commit}"], allowFailure: true)
        async let symbolicResult = referenceCommand(["symbolic-ref", "--quiet", "HEAD"], allowFailure: true)
        let (head, symbolic) = try await (headResult, symbolicResult)
        guard [0, 1].contains(head.exitCode), [0, 1].contains(symbolic.exitCode) else {
            throw GitError.invalidReference
        }
        return HeadState(commit: head.exitCode == 0 ? GitOutput.line(head.stdout) : nil, symbolic: symbolic)
    }

    private func branchReview(
        _ shortName: String, record: ReferenceRecord, commitID: String?, head: String?, common: URL,
        identity: inout Fingerprint
    ) async throws -> BranchReview {
        let remote = try await referenceConfig("branch." + shortName + ".remote")
        let merge = try await referenceConfig("branch." + shortName + ".merge")
        identity.add("branch.remote", remote)
        identity.add("branch.merge", merge)
        var review = BranchReview()
        if !remote.isEmpty || !merge.isEmpty {
            review = try await upstreamReview(record: record, remote: remote, merge: merge, identity: &identity)
        } else {
            review.mergeTarget = head == nil ? nil : "HEAD"
            review.mergeCommit = head
        }
        // Match ancestry checks and the final porcelain command. Replacement
        // refs are disabled; shallow boundaries and grafts remain relevant.
        for path in ["shallow", "info/grafts"] {
            identity.add(path, try BoundedFile.contents(common.appendingPathComponent(path)))
        }
        if let commitID, let mergeCommit = review.mergeCommit {
            let result = try await referenceCommand(
                ["merge-base", "--is-ancestor", commitID, mergeCommit], allowFailure: true)
            guard [0, 1].contains(result.exitCode) else {
                throw ReferenceError.mergeAncestryUnknown
            }
            review.ancestry = result.exitCode == 0 ? .merged : .unmerged
        }
        return review
    }

    /// Multiple or partial upstream configuration is not a verified single merge destination.
    private func upstreamReview(
        record: ReferenceRecord, remote: Data, merge: Data, identity: inout Fingerprint
    ) async throws -> BranchReview {
        let remoteName = Self.singleValue(remote)
        let mergeRef = Self.singleValue(merge)
        let upstreamRecord = record.upstream.isEmpty ? nil : try await optionalReferenceRecord(record.upstream)
        let validTarget = upstreamRecord.flatMap {
            $0.symbolicTarget.isEmpty && $0.objectType == "commit" ? $0.objectID : nil
        }
        let missing = remoteName == nil || mergeRef == nil || validTarget == nil
        identity.add("upstream", upstreamRecord?.bytes)
        if let remoteName, remoteName != "." {
            identity.add("upstream-fetch", try await referenceConfig("remote." + remoteName + ".fetch"))
        }
        return BranchReview(
            upstream: GitReferenceUpstream(
                fullName: record.upstream.isEmpty ? nil : record.upstream, objectID: validTarget,
                remoteName: remoteName, mergeRef: mergeRef, isMissing: missing),
            mergeTarget: missing ? nil : record.upstream, mergeCommit: missing ? nil : validTarget)
    }

    func referenceRecord(_ fullName: String) async throws -> ReferenceRecord {
        guard let result = try await optionalReferenceRecord(fullName) else { throw GitError.invalidReference }
        return result
    }

    private func optionalReferenceRecord(_ fullName: String) async throws -> ReferenceRecord? {
        let output = try await referenceCommand([
            "for-each-ref", "--count=2", "--sort=refname", "--format=" + ReferenceRecord.format, "--", fullName,
        ])
        return try ReferenceRecord.parse(output.stdout, fullName: fullName)
    }

    func referenceDirectories() async throws -> ReferenceDirectories {
        let (worktree, common) = try await gitDirectories()
        guard worktree.hasPrefix("/"), common.hasPrefix("/") else { throw GitError.notRepository }
        return ReferenceDirectories(
            worktree: URL(fileURLWithPath: worktree).resolvingSymlinksInPath(),
            common: URL(fileURLWithPath: common).resolvingSymlinksInPath())
    }

    private func referenceConfig(_ key: String) async throws -> Data {
        let result = try await referenceCommand(["config", "--null", "--get-all", key], allowFailure: true)
        guard [0, 1].contains(result.exitCode) else {
            throw ReferenceError.configurationUnreadable
        }
        return result.stdout
    }

    private static func singleValue(_ data: Data) -> String? {
        let values = data.split(separator: GitOutput.nul, omittingEmptySubsequences: false)
        guard values.count == 2, values[1].isEmpty, !values[0].isEmpty else { return nil }
        return String(data: Data(values[0]), encoding: .utf8)
    }

    /// Only fetch refspecs are read, never remote URLs or authentication config.
    /// Include all matching remotes: adding a second match makes tracking ambiguous.
    func referenceFetchMappings(_ fullName: String) async throws -> Data {
        let result = try await referenceCommand(
            ["config", "--null", "--get-regexp", #"^remote\..*\.fetch$"#], allowFailure: true)
        guard [0, 1].contains(result.exitCode) else {
            throw ReferenceError.fetchMappingUnreadable
        }
        var records: [(key: Data, value: Data)] = []
        var matchingKeys = Set<Data>()
        for record in result.stdout.split(separator: GitOutput.nul) {
            guard let separator = record.firstIndex(of: GitOutput.lineFeed),
                let spec = String(data: Data(record[record.index(after: separator)...]), encoding: .utf8)
            else { throw ReferenceError.invalidFetchMapping }
            let key = Data(record[..<separator])
            records.append((key, Data(record)))
            if FetchRefspec(spec)?.destinationMatches(fullName) == true { matchingKeys.insert(key) }
        }
        // Negative/exact companion refspecs also belong to the selected remote's
        // mapping, even when they do not themselves name a destination ref.
        var matching = Data()
        for record in records where matchingKeys.contains(record.key) {
            matching.append(record.value)
            matching.append(GitOutput.nul)
        }
        return matching
    }
}

/// A worktree's own `.git` directory and the repository's common one, symlinks resolved.
struct ReferenceDirectories {
    var worktree: URL
    var common: URL
}
