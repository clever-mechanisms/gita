import AppKit
import Foundation
import Testing

@testable import GitaCore
@testable import GitaUI

/// A provider CLI stand-in: records every command and answers from `respond` (by default: not installed). The real
/// `gh`, `vercel` and `orca` never run.
actor ModelCommandRunner: CommandRunning {
    struct Call: Sendable {
        let executable: String
        let arguments: [String]
    }

    private(set) var calls: [Call] = []
    private let respond: @Sendable (Call) throws -> CommandResult

    init(
        respond: @escaping @Sendable (Call) throws -> CommandResult = {
            throw CommandError.executableNotFound($0.executable)
        }
    ) {
        self.respond = respond
    }

    func run(
        executable: String, arguments: [String], directory _: URL?, timeout _: TimeInterval, outputLimit _: Int
    ) async throws -> CommandResult {
        let call = Call(executable: executable, arguments: arguments)
        calls.append(call)
        return try respond(call)
    }

    func executables() -> [String] { calls.map(\.executable) }

    static func output(_ text: String, exitCode: Int32 = 0) -> CommandResult {
        CommandResult(stdout: Data(text.utf8), stderr: Data(), exitCode: exitCode)
    }
}

/// What an `AppModel` under test sent outside: alerts, avatar lookups and notifications.
@MainActor
final class ModelRecorder {
    private(set) var errors: [String] = []
    private(set) var avatarLookups: [URL] = []
    private(set) var providerNotifications = 0
    private(set) var vercelAlerts: [String] = []

    /// A model over `defaults` that records instead of reaching out.
    func model(defaults: UserDefaults, runner: ModelCommandRunner, drafts: URL) -> AppModel {
        AppModel(
            defaults: defaults, providers: ProviderService(runner: runner),
            alerts: AlertPresenter { [weak self] alert, _, _ in self?.errors.append(alert.messageText) },
            dependencies: dependencies(runner: runner, drafts: drafts))
    }

    private func dependencies(runner: ModelCommandRunner, drafts: URL) -> AppModelDependencies {
        AppModelDependencies(
            vercelActions: VercelActionService(runner: runner),
            lookUpAvatars: { [weak self] root, _, _ in self?.avatarLookups.append(root) },
            notifyProvider: { [weak self] _ in self?.providerNotifications += 1 },
            notifyVercelAlert: { [weak self] alert, _, _ in self?.vercelAlerts.append(alert.id) },
            openCommitDraft: { try CommitMessageDraft.open(root: $0, gitDirectory: $1, in: drafts) })
    }
}

/// An `AppModel` over a disposable repository, with its own defaults suite, drafts folder and recording CLIs.
@MainActor
final class ModelHarness {
    let repository: TemporaryRepository
    let defaults: UserDefaults
    let recorder = ModelRecorder()
    let runner: ModelCommandRunner
    let model: AppModel
    private let suiteName = "GitaUITests.Model.\(UUID().uuidString)"
    private let drafts: URL

    init(repository: TemporaryRepository? = nil, runner: ModelCommandRunner = ModelCommandRunner()) throws {
        UITestSupport.bootstrap()
        self.repository = try repository ?? TemporaryRepository()
        self.runner = runner
        guard let defaults = UserDefaults(suiteName: suiteName) else { throw ModelTestError.noDefaults }
        self.defaults = defaults
        drafts = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitaUITests-Drafts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: drafts, withIntermediateDirectories: true)
        model = recorder.model(defaults: defaults, runner: runner, drafts: drafts)
    }

    isolated deinit {
        model.stop()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: drafts)
    }

    var url: URL { repository.url }

    /// Another tab's model: the same defaults, drafts and CLIs.
    func sibling() -> AppModel {
        recorder.model(defaults: defaults, runner: runner, drafts: drafts)
    }

    /// Opens the repository and waits for its first snapshot.
    func open() async throws {
        model.open(url)
        // The first snapshot also reads every provider: done once their reports (and logs) are in.
        let model = model
        try await settle { !model.providers.full.isRunning }
        try #require(model.snapshot != nil)
    }

    /// Waits until no read or mutation runs and `condition` holds.
    func settle(_ condition: @escaping @MainActor () -> Bool = { true }) async throws {
        let model = model
        let settled = await eventually { !model.isLoading && !model.isMutating && condition() }
        try #require(
            settled,
            "not settled: loading \(model.isLoading), mutating \(model.isMutating), status \(model.status), condition \(condition())"
        )
    }

    /// The loaded commit with `subject`.
    func commit(_ subject: String) throws -> GitCommit {
        try #require(model.snapshot?.commits.first { $0.subject == subject })
    }
}

enum ModelTestError: Error { case noDefaults, importFailed }

/// Polls `condition` on the main actor until it holds, at most `timeout`: a wait for completion, never a fixed sleep.
@MainActor
func eventually(timeout: Duration = .seconds(60), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        guard clock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

extension TemporaryRepository {
    /// Writes `count` commits on `branch` in one `git fast-import` (a fresh repository only), then checks them out.
    func importCommits(_ count: Int, branch: String = "main") throws {
        var stream = ""
        for index in 1...count {
            let message = "Commit \(index)"
            let contents = "line \(index)\n"
            stream += "commit refs/heads/\(branch)\n"
            stream += "committer Gita Tests <tests@example.invalid> \(1_700_000_000 + index) +0000\n"
            stream += "data \(message.utf8.count)\n\(message)\n"
            stream += "M 644 inline file.txt\ndata \(contents.utf8.count)\n\(contents)\n"
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["fast-import", "--quiet"]
        process.currentDirectoryURL = url
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": url.path, "GIT_CONFIG_NOSYSTEM": "1"]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        input.fileHandleForWriting.write(Data(stream.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ModelTestError.importFailed }
        try git("reset", "-q", "--hard")
    }

    /// A merge of `branch` into the current branch, never fast-forwarded.
    func merge(_ branch: String, message: String) throws {
        try git("merge", "-q", "--no-ff", "-m", message, branch)
    }
}
