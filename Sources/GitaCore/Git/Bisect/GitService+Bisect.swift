import Foundation

/// Visual `git bisect` lifecycle commands and state inspection.
extension GitService {
    /// Exit status Git returns when only skipped commits remain to test.
    private static let bisectOnlySkippedExit: Int32 = 2

    /// Reads the current bisect state (`.inactive`, `.active`, or `.finished`).
    /// Checks `BISECT_START` before spawning extra Git reads so inactive repos pay zero extra subprocess cost.
    public func bisectState() async throws -> BisectState {
        try Task.checkCancellation()
        let dirResult = try await execute(["rev-parse", "--absolute-git-dir"], timeout: 10, outputLimit: 64 * 1_024)
        let gitDirectory = URL(fileURLWithPath: GitOutput.withoutTerminalLF(dirResult.text), isDirectory: true)
        guard FileManager.default.fileExists(atPath: gitDirectory.appendingPathComponent("BISECT_START").path) else {
            return .inactive
        }
        async let head = headCommit()
        async let refs = bisectRefs()
        let (headID, bisectRefMap) = try await (head, refs)
        guard let raw = try BisectStateReader.read(gitDirectory: gitDirectory, head: headID, bisectRefs: bisectRefMap)
        else {
            return .inactive
        }
        if let culpritID = raw.culpritCommitID {
            let summary = try await commitSummary(culpritID)
            let subject =
                raw.culpritSubject?.isEmpty == false ? (raw.culpritSubject ?? summary.subject) : summary.subject
            return .finished(
                BisectCulprit(
                    commitID: culpritID,
                    subject: subject,
                    author: summary.author,
                    startBranch: raw.startBranch
                )
            )
        }
        return try await buildActiveBisectState(raw: raw, headID: headID)
    }

    /// Starts a new bisect session between `bad` and `good` commits.
    public func bisectStart(bad: String, good: String) async throws -> BisectState {
        try await mutate { service in
            try await service.requireCleanBisectStart()
            let badSHA = try await service.resolveCommit(bad, verify: true)
            let goodSHA = try await service.resolveCommit(good, verify: true)
            guard badSHA != goodSHA else { throw BisectError.sameCommit }
            let result = try await service.execute(
                ["bisect", "start", badSHA, goodSHA],
                timeout: .untilIdle,
                allowFailure: true,
                mutation: true
            )
            try Self.validateBisectResult(result)
            return try await service.bisectStateAfterStep(output: result.text, badTerm: "bad")
        }
    }

    /// Marks the current (or specified) commit as good (or active custom good term) during an active bisect.
    public func bisectGood(commit: String? = nil) async throws -> BisectState {
        try await runBisectStep(kind: .good, commit: commit)
    }

    /// Marks the current (or specified) commit as bad (or active custom bad term) during an active bisect.
    public func bisectBad(commit: String? = nil) async throws -> BisectState {
        try await runBisectStep(kind: .bad, commit: commit)
    }

    /// Skips the current (or specified) untestable commit during an active bisect.
    public func bisectSkip(commit: String? = nil) async throws -> BisectState {
        try await runBisectStep(kind: .skip, commit: commit)
    }

    /// Ends the bisect session and returns HEAD to the branch or commit where bisect started.
    public func bisectReset() async throws -> BisectState {
        try await mutate { service in
            guard try await service.bisectState().isVisible else { throw BisectError.notActive }
            let result = try await service.execute(
                ["bisect", "reset"],
                timeout: .untilIdle,
                allowFailure: true,
                mutation: true
            )
            try Self.validateBisectResult(result)
            return try await service.bisectState()
        }
    }

    // MARK: Internals

    private enum BisectStepKind {
        case good
        case bad
        case skip
    }

    private func runBisectStep(kind: BisectStepKind, commit: String?) async throws -> BisectState {
        try await mutate { service in
            let current = try await service.bisectState()
            guard current.isVisible else { throw BisectError.notActive }
            let badTerm = current.session?.badTerm ?? "bad"
            let goodTerm = current.session?.goodTerm ?? "good"
            let subcommand: String =
                switch kind {
                case .good: goodTerm
                case .bad: badTerm
                case .skip: "skip"
                }
            var arguments = ["bisect", subcommand]
            if let commit {
                arguments.append(try await service.resolveCommit(commit, verify: true))
            }
            let result = try await service.execute(
                arguments,
                timeout: .untilIdle,
                allowFailure: true,
                mutation: true
            )
            try Self.validateBisectResult(result)
            return try await service.bisectStateAfterStep(output: result.text, badTerm: badTerm)
        }
    }

    private static func validateBisectResult(_ result: CommandResult) throws {
        guard result.exitCode != 0 else { return }
        let stderrText = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let stdoutText = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = stderrText.isEmpty ? stdoutText : stderrText
        if result.exitCode == bisectOnlySkippedExit {
            let safe = redactingCredentials(combined)
            throw BisectError.onlySkippedRemaining(String(safe.prefix(2_048)))
        }
        if !combined.isEmpty {
            throw GitError.commandFailed(String(redactingCredentials(combined).prefix(4_096)))
        }
        throw failure(result)
    }

    private func bisectStateAfterStep(output: String, badTerm: String) async throws -> BisectState {
        let state = try await bisectState()
        if case .finished = state { return state }
        if let culpritID = BisectStateReader.parseCulpritFromOutput(output, badTerm: badTerm) {
            let startBranch = state.session?.startBranch ?? ""
            let summary = try await commitSummary(culpritID)
            return .finished(
                BisectCulprit(
                    commitID: culpritID,
                    subject: summary.subject,
                    author: summary.author,
                    startBranch: startBranch
                )
            )
        }
        return state
    }

    private func requireCleanBisectStart() async throws {
        guard try await !bisectState().isVisible else { throw BisectError.alreadyActive }
        try await requireCleanOperationStart()
    }

    private func bisectRefs() async throws -> [String: String] {
        let result = try await execute(
            ["for-each-ref", "--format=%(refname)%00%(objectname)%00", "--", "refs/bisect/"],
            allowFailure: true
        )
        guard result.exitCode == 0 else { return [:] }
        let fields = GitOutput.nulFields(result.stdout)
        var map: [String: String] = [:]
        var index = 0
        while index + 1 < fields.count {
            let name = fields[index].trimmingCharacters(in: .newlines)
            let sha = fields[index + 1].trimmingCharacters(in: .newlines)
            if !name.isEmpty, GitParsers.isObjectID(sha) {
                map[name] = sha
            }
            index += 2
        }
        return map
    }

    private func buildActiveBisectState(
        raw: BisectStateReader.RawSnapshot, headID: String?
    ) async throws -> BisectState {
        let currentID = headID ?? ""
        async let summaryTask = commitSummary(currentID)
        async let remainingTask = remainingBisectCount(
            bad: raw.badCommitID, good: raw.goodCommitIDs, skipped: raw.skippedCommitIDs)
        let (summary, remaining) = try await (summaryTask, remainingTask)
        let steps = remaining.map(BisectStateReader.estimatedSteps(forRemaining:))
        return .active(
            BisectSession(
                startBranch: raw.startBranch,
                currentCommitID: currentID,
                currentSubject: summary.subject,
                badTerm: raw.badTerm,
                goodTerm: raw.goodTerm,
                badCommitID: raw.badCommitID,
                goodCommitIDs: raw.goodCommitIDs,
                skippedCommitIDs: raw.skippedCommitIDs,
                remainingCommits: remaining,
                estimatedSteps: steps,
                identity: raw.identity
            )
        )
    }

    private func remainingBisectCount(bad: String?, good: Set<String>, skipped: Set<String>) async throws -> Int? {
        guard let bad, GitParsers.isObjectID(bad), !good.isEmpty else { return nil }
        let sortedGood = good.filter(GitParsers.isObjectID).sorted()
        guard !sortedGood.isEmpty else { return nil }
        let arguments = ["rev-list", "--count", bad, "--not"] + sortedGood
        let result = try await execute(arguments, allowFailure: true)
        guard result.exitCode == 0,
            let total = Int(GitOutput.withoutTerminalLF(result.text).trimmingCharacters(in: .whitespaces))
        else { return nil }
        return max(0, total - 1 - skipped.count)
    }

    private func commitSummary(_ commitID: String) async throws -> (subject: String, author: String) {
        guard GitParsers.isObjectID(commitID) else { return ("", "") }
        let result = try await execute(
            ["show", "--no-patch", "--no-show-signature", "-z", "--format=%s%x00%an", commitID, "--"],
            allowFailure: true
        )
        guard result.exitCode == 0 else { return ("", "") }
        let fields = GitOutput.nulFields(result.stdout)
        let subject = fields.first ?? ""
        let author = fields.count > 1 ? fields[1] : ""
        return (subject, author)
    }
}
