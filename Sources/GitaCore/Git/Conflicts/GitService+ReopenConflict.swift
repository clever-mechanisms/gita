import Foundation

/// Reopen: brings back the conflict of a file resolved during the operation, from Git's resolve-undo record in the
/// index. It replaces the staged result and the working file, so a file with unstaged edits is refused.
extension GitService {
    public func reopenConflict(path: String, expected: GitOperationState) async throws {
        try GitInput.validatePath(path)
        try GitInput.validateComponents(path)
        try await mutate { service in
            guard try await service.operationState() == expected else { throw GitError.operationChanged }
            guard try await service.resolvedConflictPaths().contains(path) else { throw ReopenConflictError.noRecord }
            let unstaged = try await service.execute(["diff", "--quiet", "--", path], allowFailure: true)
            guard unstaged.exitCode == 0 else { throw ReopenConflictError.unstagedChanges }
            _ = try await service.execute(["checkout", "--merge", "--", path], mutation: true)
        }
    }

    /// `ls-files --resolve-undo -z`: "mode object stage<TAB>path" records, one per stage.
    func resolvedConflictPaths() async throws -> Set<String> {
        let output = try await execute(["ls-files", "--resolve-undo", "-z"]).stdout
        return Set(
            output.split(separator: GitOutput.nul).compactMap { record in
                record.firstIndex(of: UInt8(ascii: "\t")).map {
                    String(decoding: record[record.index(after: $0)...], as: UTF8.self)
                }
            })
    }
}

/// Why a resolved file's conflict cannot be brought back.
enum ReopenConflictError: Error, LocalizedError, Sendable {
    case noRecord
    case unstagedChanges

    var errorDescription: String? {
        switch self {
        case .noRecord: String(localized: "Git has no record of a conflict in this file.")
        case .unstagedChanges:
            String(localized: "The file has unstaged changes. Stage or discard them before reopening its conflict.")
        }
    }
}
