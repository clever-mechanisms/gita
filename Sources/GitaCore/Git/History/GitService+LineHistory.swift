import Foundation

/// Traces how a range of lines evolved across commits via `git log -L start,end:path`.
extension GitService {
    private static let lineHistoryOutputLimit = 16 * 1_024 * 1_024
    private static let lineHistoryCap = 500

    public func lineHistory(range: LineRangeSpec, limit: Int = 100) async throws -> [LineHistoryEntry] {
        try Task.checkCancellation()
        guard range.isValid else { throw CommandError.invalidArgument }
        try GitInput.validatePath(range.path)
        let revision: String?
        if let rev = range.revision {
            try GitInput.validateReference(rev)
            revision = try await resolveCommit(rev, verify: true)
        } else {
            revision = nil
        }
        let clampedLimit = min(max(limit, 1), Self.lineHistoryCap)
        let lineSpec = "\(range.startLine),\(range.endLine):\(range.path)"
        var arguments =
            [
                "log", "--no-show-signature", "--decorate=short",
                "--max-count=\(clampedLimit)",
                "--format=" + LineHistoryParser.format,
                "--src-prefix=a/", "--dst-prefix=b/",
            ] + GitArguments.safeDiff + ["-L", lineSpec]
        if let revision {
            arguments.append(revision)
        }
        let result = try await execute(arguments, timeout: .standard, outputLimit: Self.lineHistoryOutputLimit)
        let text = result.text
        let work = Task.detached(priority: .userInitiated) {
            LineHistoryParser.parse(text)
        }
        let entries = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        try Task.checkCancellation()
        return entries
    }
}
