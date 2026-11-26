import Foundation

extension GitService {
    public func createStash(_ request: StashCreateRequest) async throws {
        let arguments = try request.arguments()
        try await mutate { service in
            try await service.requireNoOperation()
            let result = try await service.execute(arguments, mutation: true)
            if result.text.hasPrefix("No local changes to save") { throw StashManagementError.noChangesToStash }
        }
    }

    private static func validateStashRef(_ ref: String) throws {
        try GitInput.validateReference(ref)
        guard GitInput.isStashReference(ref) else { throw GitError.invalidReference }
    }

    private func verifyStashCommit(ref: String, expectedCommitID: String?) async throws {
        guard let expectedCommitID else { return }
        guard GitParsers.isObjectID(expectedCommitID) else { throw GitError.invalidReference }
        let resolved = try await execute(
            ["rev-parse", "--verify", "--quiet", "--end-of-options", ref + "^{commit}"], allowFailure: true)
        guard resolved.exitCode == 0, GitOutput.withoutTerminalLF(resolved.text) == expectedCommitID else {
            throw GitError.staleReference
        }
    }

    public func popStash(
        ref: String, expectedCommitID: String? = nil, restoreIndex: Bool = true
    ) async throws -> StashPopOutcome {
        try Self.validateStashRef(ref)
        return try await mutate { service in
            try await service.requireNoOperation()
            try await service.verifyStashCommit(ref: ref, expectedCommitID: expectedCommitID)
            let beforeID = try? await service.resolveCommit(ref, verify: true)
            let args = ["stash", "pop"] + (restoreIndex ? ["--index"] : []) + [ref]
            let result = try await service.execute(args, allowFailure: true, mutation: true)
            if result.exitCode == 0 { return .applied }
            return try await service.classifyPopFailure(
                result, ref: ref, beforeID: beforeID, restoreIndex: restoreIndex)
        }
    }

    private func classifyPopFailure(
        _ result: CommandResult, ref: String, beforeID: String?, restoreIndex: Bool
    ) async throws -> StashPopOutcome {
        let diagnostic = Self.popDiagnostic(result)
        let unmerged = try await unmergedIndex()
        if !unmerged.isEmpty { return .conflictedStashKept(diagnostic) }
        if restoreIndex, Self.isIndexRestoreFailure(diagnostic),
            let beforeID, (try? await resolveCommit(ref, verify: true)) == beforeID
        {
            return .indexConflictRetryWithoutIndex(diagnostic)
        }
        throw Self.failure(result)
    }

    private static func popDiagnostic(_ result: CommandResult) -> String {
        let raw = result.stderr.isEmpty ? result.stdout : result.stderr
        return Self.failure(CommandResult(stdout: Data(), stderr: raw, exitCode: result.exitCode)).localizedDescription
    }

    private static func isIndexRestoreFailure(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("conflicts in index") || lower.contains("without --index")
            || lower.contains("could not restore") || lower.contains("index entry")
    }

    public func dropStash(ref: String, expectedCommitID: String? = nil) async throws {
        try Self.validateStashRef(ref)
        try await mutate { service in
            try await service.verifyStashCommit(ref: ref, expectedCommitID: expectedCommitID)
            _ = try await service.execute(["stash", "drop", ref], mutation: true)
        }
    }

    public func createBranchFromStash(name: String, ref: String, expectedCommitID: String? = nil) async throws {
        try Self.validateStashRef(ref)
        try await mutate { service in
            try await service.requireNoOperation()
            try await service.verifyStashCommit(ref: ref, expectedCommitID: expectedCommitID)
            try await service.validateBranch(name)
            guard !name.contains("@{") else { throw GitError.invalidReference }
            _ = try await service.execute(["stash", "branch", name, ref], mutation: true)
        }
    }
}

extension StashCreateRequest {
    public func validate() throws { _ = try arguments() }

    fileprivate func arguments() throws -> [String] {
        guard !message.contains("\0") else { throw CommandError.invalidArgument }
        var arguments = ["stash", "push"]
        var pathspecs: [String] = []
        switch scope {
        case .allIncludingUntracked: arguments.append("--include-untracked")
        case .trackedOnly: break
        case .stagedOnly:
            guard !keepIndex else { throw StashManagementError.keepIndexUnsupportedForStagedOnly }
            arguments.append("--staged")
        case .selectedPaths(let paths):
            guard !paths.isEmpty else { throw StashManagementError.emptySelectedPaths }
            arguments.append("--include-untracked")
            pathspecs = try paths.map { path in
                try GitInput.validatePath(path)
                guard !path.hasPrefix(":") else { throw GitError.invalidPath }
                return ":(literal)" + path
            }
        }
        if keepIndex { arguments.append("--keep-index") }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { arguments += ["-m", trimmed] }
        return arguments + (pathspecs.isEmpty ? [] : ["--"] + pathspecs)
    }
}
