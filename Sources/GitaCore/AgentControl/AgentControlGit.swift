import Foundation

/// All index writes use a private index, including the index Git consults to remove
/// paths during a restore. Optional status refreshes and repository hooks stay off.
struct AgentControlGit: Sendable {
    let root: URL
    let runner: any CommandRunning
    var index: URL?

    @discardableResult
    func run(
        _ args: [String], accepting codes: [Int32] = [0], limit: Int = CommandRequest.defaultOutputLimit
    ) async throws -> CommandResult {
        let options =
            GitArguments.globalOptions(for: args, mutation: false) + GitArguments.noHooks
            + FSMonitorHardening.disabled + ["-c", "core.splitIndex=false"]
        var request = CommandRequest.git(options + args, directory: root, outputLimit: limit)
        request.environment.added["GIT_INDEX_FILE"] = index?.path
        let result = try await runner.run(request)
        guard codes.contains(result.exitCode) else { throw GitService.failure(result) }
        return result
    }

    func oid(_ args: [String]) async throws -> String {
        let result = try await run(args)
        let oid = GitOutput.withoutTerminalLF(result.text)
        guard GitParsers.isObjectID(oid) else { throw GitError.invalidReference }
        return oid
    }

    func resolve(_ ref: String) async throws -> String? {
        try GitInput.validateReference(ref)
        let result = try await run(
            ["rev-parse", "--verify", "--quiet", "--end-of-options", ref + "^{commit}"],
            accepting: [0, 1])
        guard result.exitCode == 0 else { return nil }
        let oid = GitOutput.withoutTerminalLF(result.text)
        guard GitParsers.isObjectID(oid) else { throw GitError.invalidReference }
        return oid
    }

    func withWorktreeIndex<T: Sendable>(
        _ operation: @Sendable (Self) async throws -> T
    ) async throws -> T {
        let temporary = try PrivateTemporaryDirectory.make(
            prefix: "GitaFlightIndex", failure: LocalFileError.destinationNotCreated)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let index = temporary.appendingPathComponent("index")
        let isolated = Self(root: root, runner: runner, index: index)
        // CommandRunning's legacy argv-only adapter drops environment overrides.
        let location = try await isolated.run(["rev-parse", "--git-path", "index"])
        guard GitOutput.line(location.stdout) == index.path else { throw CommandError.invalidArgument }
        if let head = try await resolve("HEAD") { try await isolated.run(["read-tree", head]) }
        try await includeIgnoredTrackedFiles(in: isolated)
        try await isolated.run(["add", "-A", "--", "."])
        return try await operation(isolated)
    }

    /// A force-added ignored file can be tracked only in the real index.
    private func includeIgnoredTrackedFiles(in isolated: Self) async throws {
        let files = try await run(["ls-files", "-ci", "--exclude-standard", "-z"])
        for path in GitOutput.nulFields(files.stdout) where !path.isEmpty {
            try GitInput.validateComponents(path)
            let url = root.appendingPathComponent(path)
            if (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil {
                try await isolated.run(["add", "-f", "--", path])
            }
        }
    }

    func worktreeTree() async throws -> String {
        try await withWorktreeIndex { try await $0.oid(["write-tree"]) }
    }

    static let diffLimit = 2 * 1_024 * 1_024
    static let diffOptions =
        ["diff", "--no-renames", "--submodule=short", "--src-prefix=a/", "--dst-prefix=b/"] + GitArguments.safeDiff

    func files(from: String, to: String, paths: [String] = []) async throws -> [String] {
        let result = try await run(Self.diffOptions + ["--name-only", "-z", from, to, "--"] + paths)
        return GitOutput.nulFields(result.stdout).filter { !$0.isEmpty }
    }

    func diff(from: String, to: String, paths: [String] = []) async throws -> (text: String, truncated: Bool) {
        let args = Self.diffOptions + [from, to, "--"] + paths
        do {
            let result = try await run(args, limit: Self.diffLimit)
            return Self.excerpt(result.stdout, limit: Self.diffLimit)
        } catch CommandError.outputLimitExceeded {
            return try await withDiffFile(from: from, to: to, paths: paths) {
                try Self.prefix(of: $0, limit: Self.diffLimit)
            }
        }
    }

    func fullDiff(from: String, to: String) async throws -> String {
        do {
            return try await run(Self.diffOptions + [from, to, "--"]).text
        } catch CommandError.outputLimitExceeded {
            return try await withDiffFile(from: from, to: to, paths: []) {
                String(decoding: try Data(contentsOf: $0, options: .mappedIfSafe), as: UTF8.self)
            }
        }
    }

    /// CommandRunner discards overflow output. Git can spool the patch directly to a private file.
    private func withDiffFile<T: Sendable>(
        from: String, to: String, paths: [String], read: @Sendable (URL) throws -> T
    ) async throws -> T {
        let directory = try PrivateTemporaryDirectory.make(
            prefix: "GitaDiff", failure: LocalFileError.destinationNotCreated)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("patch")
        try await run(Self.diffOptions + ["--output=" + file.path, from, to, "--"] + paths)
        return try read(file)
    }

    static func prefix(of file: URL, limit: Int) throws -> (text: String, truncated: Bool) {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        return excerpt(data, limit: limit)
    }

    /// A replacement character or an incomplete UTF-8 scalar must not expand an excerpt past its byte budget.
    static func excerpt(_ data: Data, limit: Int) -> (text: String, truncated: Bool) {
        let text = String(decoding: data.prefix(limit), as: UTF8.self)
        guard text.utf8.count > limit else { return (text, data.count > limit) }
        var bytes = text.utf8.prefix(limit)
        if let start = bytes.lastIndex(where: { $0 < 128 || $0 >= 192 }),
            String(bytes: bytes[start...], encoding: .utf8) == nil
        {
            bytes = bytes[..<start]
        }
        return (String(decoding: bytes, as: UTF8.self), true)
    }
}
