import Foundation

/// Code search across commit history via Git pickaxe (`git log -S` literal and `-G` regex).
extension GitService {
    private static let pickaxeOutputLimit = 8 * 1_024 * 1_024
    private static let pickaxePatternLimit = 16_384
    private static let pickaxeCap = 500

    /// Searches commit history lightly (`--name-only`, no full patches up front) so large lockfiles never blow limits.
    public func searchCode(_ query: PickaxeQuery) async throws -> [PickaxeMatch] {
        try Task.checkCancellation()
        guard !query.pattern.isEmpty, !query.pattern.contains("\0"),
            query.pattern.utf8.count <= Self.pickaxePatternLimit
        else { throw CommandError.invalidArgument }
        if let pathFilter = query.pathFilter {
            try GitInput.validatePath(pathFilter)
        }
        guard try await headCommit() != nil else { return [] }
        let clampedLimit = min(max(query.limit, 1), Self.pickaxeCap)
        var arguments =
            [
                "log", "--no-show-signature", "--decorate=short", "--name-only",
                "--max-count=\(clampedLimit)",
                "--format=" + LineHistoryParser.format,
                "--src-prefix=a/", "--dst-prefix=b/",
            ] + GitArguments.safeDiff + [query.mode.gitFlag, query.pattern]
        if query.ignoreCase {
            arguments.append("--regexp-ignore-case")
        }
        if let pathFilter = query.pathFilter {
            arguments += ["--", pathFilter]
        } else {
            arguments.append("--")
        }
        let result = try await execute(arguments, timeout: 60, outputLimit: Self.pickaxeOutputLimit)
        let text = result.text
        let work = Task.detached(priority: .userInitiated) {
            PickaxeParser.parseNameOnly(text)
        }
        let matches = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        try Task.checkCancellation()
        return matches
    }

    /// Loads one matched file's diff on demand for a pickaxe search result.
    public func pickaxeFileDiff(commitID: String, path: String?) async throws -> String {
        guard GitParsers.isObjectID(commitID) else { throw GitError.invalidReference }
        if let path { try GitInput.validatePath(path) }
        return try await diff(path: path, commit: commitID)
    }
}
