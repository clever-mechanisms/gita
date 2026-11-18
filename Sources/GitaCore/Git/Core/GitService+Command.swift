import Foundation

/// The one way GitService runs Git, and the presets built on it.
extension GitService {
    /// Runs `git` in the repository root. Every command gets a pager-free, colour-free, unquoted-path invocation
    /// and literal pathspecs; reads also skip optional locks and a repository-supplied fsmonitor hook.
    /// A non-zero exit throws Git's (redacted) diagnostic unless `allowFailure`.
    func execute(
        _ arguments: [String], timeout: GitTimeout = .standard,
        outputLimit: Int = CommandRequest.defaultOutputLimit, allowFailure: Bool = false, mutation: Bool = false,
        editors: GitEditorEnvironment? = nil
    ) async throws -> CommandResult {
        var request = try await gitRequest(arguments, outputLimit: outputLimit, mutation: mutation)
        request.editors = editors
        timeout.apply(to: &request)
        let result = try await runner.run(request)
        guard allowFailure || result.exitCode == 0 else { throw Self.failure(result) }
        return result
    }

    /// The request `execute` runs: Git in the repository root with the global options and, for a read, the
    /// fsmonitor hardening.
    func gitRequest(_ arguments: [String], outputLimit: Int, mutation: Bool = false) async throws -> CommandRequest {
        try Task.checkCancellation()
        let directory = try await repositoryRoot()
        let hardening = mutation ? [] : await FSMonitorHardening.shared.readOptions(root: directory, runner: runner)
        try Task.checkCancellation()
        let command = GitArguments.globalOptions(for: arguments, mutation: mutation) + hardening + arguments
        return CommandRequest.git(command, directory: directory, outputLimit: outputLimit)
    }

    /// Git's own diagnostic, with credentials embedded in any URL removed; remote errors can echo such a URL.
    static func failure(_ result: CommandResult) -> GitError {
        let message = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = redactingCredentials(message)
        return .commandFailed(
            safe.isEmpty ? String(localized: "Git exited with status \(result.exitCode).") : String(safe.prefix(4_096)))
    }

    /// Drops the user-information part of every `scheme://user[:password]@` URL. The password may itself contain
    /// `@` or `/`, so everything up to the last `@` of the whitespace-free token goes.
    static func redactingCredentials(_ text: String) -> String {
        text.replacingOccurrences(of: #"([A-Za-z][A-Za-z0-9+.-]*://)\S*@"#, with: "$1", options: .regularExpression)
    }

    // MARK: Local object access

    /// Options that keep object reads local: `--no-lazy-fetch` where Git supports it. An older Git cannot promise
    /// that, so a partial clone (which would fetch missing objects) is refused there instead. The repository
    /// configuration is re-read every time: it can change while a review is open.
    func localObjectOptions() async throws -> [String] {
        if try await probeNoLazyFetch() { return ["--no-lazy-fetch"] }
        let partialClone = try await execute(
            ["config", "--null", "--get-all", "extensions.partialclone"], timeout: 10, outputLimit: 256 * 1_024,
            allowFailure: true)
        let promisors = try await execute(
            ["config", "--null", "--type=bool", "--get-regexp", #"^remote\..*\.promisor$"#], timeout: 10,
            outputLimit: 256 * 1_024, allowFailure: true)
        guard [0, 1].contains(partialClone.exitCode), [0, 1].contains(promisors.exitCode) else {
            throw RepositoryInspectionError.objectConfigurationUnverified
        }
        let hasPromisor = promisors.stdout.split(separator: GitOutput.nul).contains {
            $0.suffix(5).elementsEqual(Data("\ntrue".utf8))
        }
        guard partialClone.exitCode == 1, !hasPromisor else {
            throw RepositoryInspectionError.partialCloneUnsupported
        }
        return []
    }

    private func probeNoLazyFetch() async throws -> Bool {
        if case .known(let supported) = noLazyFetch { return supported }
        let probe = try await execute(
            ["--no-lazy-fetch", "--version"], timeout: 10, outputLimit: 4_096, allowFailure: true)
        guard probe.exitCode == 0 || probe.exitCode == GitExit.usage else {
            throw RepositoryInspectionError.objectInspectionUnknown
        }
        noLazyFetch = .known(probe.exitCode == 0)
        return probe.exitCode == 0
    }

    /// Reference review reads: local objects only, replacement refs off, a 20 s deadline and a 2 MB cap.
    func referenceCommand(
        _ arguments: [String], allowFailure: Bool = false, mutation: Bool = false
    ) async throws -> CommandResult {
        let local = try await localObjectOptions()
        return try await execute(
            ["--no-replace-objects"] + local + arguments, timeout: 20, outputLimit: 2 * 1_024 * 1_024,
            allowFailure: allowFailure, mutation: mutation)
    }

    /// Reset and remote management: no hooks, no fsmonitor, accepted exit codes only, and a fixed `failure`
    /// message instead of Git's diagnostic, which can contain configuration values and credentials.
    func managementCommand(
        _ arguments: [String], timeout: GitTimeout = 20, outputLimit: Int = CommandRequest.defaultOutputLimit,
        allowed: Set<Int32> = [0], mutation: Bool = false,
        failure: any Error = RepositoryInspectionError.managementStateUnreadable
    ) async throws -> CommandResult {
        let result = try await execute(
            ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"] + arguments,
            timeout: timeout, outputLimit: outputLimit, allowFailure: true, mutation: mutation)
        guard allowed.contains(result.exitCode) else { throw failure }
        return result
    }

    // MARK: Repository locations

    /// The repository's `.git` directories, as Git reports them (absolute, symlinks unresolved).
    func gitDirectories() async throws -> (gitDirectory: String, commonDirectory: String) {
        async let directory = execute(["rev-parse", "--absolute-git-dir"], timeout: 10, outputLimit: 64 * 1_024)
        async let common = execute(
            ["rev-parse", "--path-format=absolute", "--git-common-dir"], timeout: 10, outputLimit: 64 * 1_024)
        let (directoryResult, commonResult) = try await (directory, common)
        return (GitOutput.withoutTerminalLF(directoryResult.text), GitOutput.withoutTerminalLF(commonResult.text))
    }

    /// HEAD's commit, or nil in an unborn repository.
    func headCommit() async throws -> String? {
        let head = try await execute(["rev-parse", "--verify", "--quiet", "HEAD"], allowFailure: true)
        return head.exitCode == 0 ? GitOutput.withoutTerminalLF(head.text) : nil
    }
}

/// Exit statuses with a meaning beyond success and failure.
enum GitExit {
    /// Usage error, e.g. an option this Git version does not know.
    static let usage: Int32 = 129
}
