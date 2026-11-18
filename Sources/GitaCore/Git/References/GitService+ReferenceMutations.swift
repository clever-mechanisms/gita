import Foundation

/// Reference writes. Each re-reads its reviewed reference inside the mutation gate and refuses any change since.
extension GitService {
    private static let tagMessageLimit = 64 * 1_024

    public func renameBranch(_ expected: GitReferenceDetails, to name: String) async throws {
        try await mutate { service in
            try await service.requireReferenceWrite()
            let current = try await service.reviewedReference(expected, kind: .branch)
            try await service.validateNewReference(name, kind: .branch)
            guard current.worktreePaths.allSatisfy({ GitOutput.same($0, current.root.path) }) else {
                throw GitError.referenceInUse
            }
            guard !GitOutput.same(current.reference.name, name) else { throw GitError.invalidReference }
            // Native -m preserves branch configuration and reflog; never use -M.
            _ = try await service.referenceCommand(
                ["branch", "--move", "--", current.reference.name, name], mutation: true)
        }
    }

    public func deleteMergedBranch(_ expected: GitReferenceDetails) async throws {
        try await mutate { service in
            try await service.requireReferenceWrite()
            let current = try await service.reviewedReference(expected, kind: .branch)
            guard current.worktreePaths.isEmpty else { throw GitError.referenceInUse }
            guard current.upstream?.isMissing != true else {
                throw ReferenceError.upstreamMissing
            }
            guard current.mergeStatus == .merged else { throw GitError.branchNotMerged }
            // -d supplies Git's final worktree/merge checks and branch config
            // cleanup. It has no expected-old-OID flag: this is not external CAS.
            _ = try await service.referenceCommand(
                ["branch", "--delete", "--", current.reference.name], mutation: true)
        }
    }

    public func setUpstream(_ expected: GitReferenceDetails, to upstream: GitReferenceDetails?) async throws {
        try await mutate { service in
            try await service.requireReferenceWrite()
            let current = try await service.reviewedReference(expected, kind: .branch)
            guard let upstream else {
                _ = try await service.referenceCommand(
                    ["branch", "--unset-upstream", "--", current.reference.name], mutation: true)
                return
            }
            let target = try await service.reviewedUpstream(upstream, for: current)
            // Tracking review does not authorize changing pull/rebase policy.
            _ = try await service.referenceCommand(
                [
                    "-c", "branch.autoSetupRebase=never", "branch", "--set-upstream-to=" + target.reference.fullName,
                    "--", current.reference.name,
                ], mutation: true)
        }
    }

    private func reviewedUpstream(
        _ upstream: GitReferenceDetails, for current: GitReferenceDetails
    ) async throws -> GitReferenceDetails {
        guard upstream.reference.kind == .branch || upstream.reference.kind == .remote else {
            throw GitError.invalidReference
        }
        let target = try await reviewedReference(upstream, kind: upstream.reference.kind)
        guard !GitOutput.same(current.reference.fullName, target.reference.fullName), target.objectType == "commit"
        else { throw GitError.invalidReference }
        if target.reference.kind == .remote, try await referenceFetchMappings(target.reference.fullName).isEmpty {
            throw ReferenceError.noFetchMapping
        }
        return target
    }

    /// An unsigned tag at an exact commit; configured signing programs never run.
    public func createTag(
        name: String, commitID: String, annotation: String?, pushToAllRemotes: Bool = false
    ) async throws {
        try await mutate { service in
            try await service.requireReferenceWrite()
            try await service.validateNewReference(name, kind: .tag)
            guard GitParsers.isObjectID(commitID) else { throw GitError.invalidReference }
            let type = try await service.referenceCommand(["cat-file", "-t", commitID], allowFailure: true)
            guard type.exitCode == 0, GitOutput.line(type.stdout) == "commit" else { throw GitError.invalidReference }
            var arguments = ["-c", "tag.gpgSign=false", "-c", "tag.forceSignAnnotated=false", "tag", "--no-sign"]
            if let annotation {
                guard !annotation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    !annotation.contains("\0"), annotation.utf8.count <= Self.tagMessageLimit
                else {
                    throw ReferenceError.tagMessage
                }
                arguments += ["--annotate", "--cleanup=verbatim", "--message", annotation]
            }
            _ = try await service.referenceCommand(arguments + ["--", name, commitID], mutation: true)
            if pushToAllRemotes { try await service.pushTagReference(GitReference.Kind.tag.prefix + name, to: nil) }
        }
    }

    /// Pushes an existing local tag to `remote`, or to every configured remote when `remote` is nil.
    public func pushTag(name: String, to remote: String? = nil) async throws {
        try await mutate { service in
            try await service.requireNoOperation()
            try await service.validateNewReference(name, kind: .tag)
            let fullName = GitReference.Kind.tag.prefix + name
            _ = try await service.execute(["show-ref", "--verify", "--quiet", fullName])
            try await service.pushTagReference(fullName, to: remote)
        }
    }

    /// Deletes a tag on `remote` without touching any local tag.
    public func deleteRemoteTag(name: String, on remote: String) async throws {
        try await mutate { service in
            try await service.requireNoOperation()
            try await service.validateNewReference(name, kind: .tag)
            try await service.requireTagRemote(remote)
            _ = try await service.execute(
                ["push", "--delete", "--", remote, GitReference.Kind.tag.prefix + name],
                timeout: .untilIdle, mutation: true)
        }
    }

    public func deleteTag(_ expected: GitReferenceDetails, deleteFromAllRemotes: Bool = false) async throws {
        try await mutate { service in
            try await service.requireReferenceWrite()
            let current = try await service.reviewedReference(expected, kind: .tag)
            // Git compares the resolved old OID, not the ref's symbolic type.
            // A same-OID symbolic replacement can lose this named tag, but
            // --no-deref preserves its referent. This is not a symbolic-type CAS.
            _ = try await service.referenceCommand(
                ["update-ref", "--no-deref", "-d", current.reference.fullName, current.objectID], mutation: true)
            if deleteFromAllRemotes { try await service.deleteTagFromAllRemotes(current.reference.fullName) }
        }
    }

    private func requireTagRemote(_ name: String) async throws {
        guard !name.hasPrefix("-"), try await remoteNames().contains(name) else { throw GitError.invalidRemote }
    }

    private func pushTagReference(_ fullName: String, to remote: String?) async throws {
        let targets: [String]
        if let remote {
            try await requireTagRemote(remote)
            targets = [remote]
        } else {
            let remotes = try await remoteNames()
            guard !remotes.isEmpty else { throw GitError.invalidRemote }
            targets = remotes
        }
        for target in targets {
            guard !target.hasPrefix("-") else { throw GitError.invalidRemote }
            _ = try await execute(["push", "--", target, fullName], timeout: .untilIdle, mutation: true)
        }
    }

    private func deleteTagFromAllRemotes(_ fullName: String) async throws {
        let remotes = try await remoteNames()
        guard !remotes.isEmpty else { throw GitError.invalidRemote }
        for target in remotes {
            guard !target.hasPrefix("-") else { throw GitError.invalidRemote }
            _ = try await execute(["push", "--delete", "--", target, fullName], timeout: .untilIdle, mutation: true)
        }
    }

    private func reviewedReference(
        _ expected: GitReferenceDetails, kind: GitReference.Kind
    ) async throws -> GitReferenceDetails {
        guard expected.reference.kind == kind, GitOutput.same(expected.root.path, try await repositoryRoot().path)
        else { throw GitError.staleReference }
        let current: GitReferenceDetails
        do {
            current = try await referenceDetails(fullName: expected.reference.fullName)
        } catch GitError.invalidReference {
            throw GitError.staleReference
        }
        guard current.fingerprint == expected.fingerprint, GitOutput.same(current.objectID, expected.objectID),
            current.reference.kind == kind
        else { throw GitError.staleReference }
        return current
    }

    private func requireReferenceWrite() async throws {
        try await requireNoOperation()
        let directory = try await referenceDirectories().worktree
        guard try BoundedFile.contents(directory.appendingPathComponent("BISECT_START")) == nil else {
            throw GitError.operationActive
        }
    }

    private func validateNewReference(_ name: String, kind: GitReference.Kind) async throws {
        guard !name.isEmpty, name != "HEAD", !name.hasPrefix("-"), !name.hasPrefix("refs/"), name.utf8.count <= 1_024
        else { throw GitError.invalidReference }
        _ = try await validateFullReference(kind.prefix + name)
    }

    func validateFullReference(_ fullName: String) async throws -> GitReference.Kind {
        guard fullName.utf8.count <= 2_048, !GitInput.containsControlCharacters(fullName),
            let kind = GitReference.Kind(fullName: fullName)
        else { throw GitError.invalidReference }
        let checked = try await referenceCommand(["check-ref-format", fullName], allowFailure: true)
        guard checked.exitCode == 0 else { throw GitError.invalidReference }
        return kind
    }
}
