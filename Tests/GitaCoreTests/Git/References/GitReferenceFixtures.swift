import Darwin
import Foundation
import Testing

@testable import GitaCore

struct ReferenceFixture {
    let container: URL
    let root: URL
    let service: GitService
    let runner = CommandRunner()

    init(seed: Bool = true, refFormat: String? = nil) async throws {
        container = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GitaReferences-" + UUID().uuidString)
        root = container.appendingPathComponent("repository\nwith space")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        service = GitService(root: root)
        try await git(
            ["init", "--initial-branch=main", "--template="] + (refFormat.map { ["--ref-format=" + $0] } ?? []))
        for (key, value) in [
            ("user.name", "Reference Tests"), ("user.email", "refs@example.invalid"),
            ("commit.gpgsign", "false"), ("tag.gpgsign", "false"), ("core.hooksPath", "/dev/null"),
        ] {
            try await git(["config", key, value])
        }
        if seed {
            try write("file.txt", "base\n")
            try await commit("Base")
        }
    }
    func remove() { try? FileManager.default.removeItem(at: container) }
    func write(_ path: String, _ value: String) throws {
        let target = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(value.utf8).write(to: target)
    }
    @discardableResult func git(
        _ arguments: [String], at directory: URL? = nil, allowFailure: Bool = false
    ) async throws -> CommandResult {
        let result = try await runner.run(
            executable: "git", arguments: arguments, directory: directory ?? root, timeout: 20,
            outputLimit: 4 * 1_024 * 1_024)
        if !allowFailure && result.exitCode != 0 {
            throw GitError.commandFailed(String(decoding: result.stderr, as: UTF8.self))
        }
        return result
    }
    @discardableResult func commit(_ message: String) async throws -> String {
        try await git(["add", "--all"])
        try await git(["commit", "-m", message])
        return try await oid("HEAD")
    }
    func oid(_ ref: String) async throws -> String {
        try await git(["rev-parse", "--verify", ref]).text.trimmingCharacters(in: .newlines)
    }
    func details(_ name: String, kind: GitReference.Kind = .branch) async throws -> GitReferenceDetails {
        let prefix = kind == .branch ? "refs/heads/" : kind == .tag ? "refs/tags/" : "refs/remotes/"
        return try await service.referenceDetails(fullName: prefix + name)
    }
    func exists(_ fullName: String) async throws -> Bool {
        try await git(["show-ref", "--verify", "--quiet", fullName], allowFailure: true).exitCode == 0
    }
}

func expectReferenceError(_ expected: GitError, _ operation: () async throws -> Void) async {
    await expectError(expected, operation)
}

enum OptionalReferenceGitFeature { case reftable, relativeWorktrees }

func supportsReferenceGitFeature(_ feature: OptionalReferenceGitFeature) async throws -> Bool {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "GitaRefCapability-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runner = CommandRunner()
    let arguments = ["init", "--bare", "--template="] + (feature == .reftable ? ["--ref-format=reftable"] : [])
    let initialized = try await runner.run(
        executable: "git", arguments: arguments, directory: directory, timeout: 10, outputLimit: 64 * 1_024)
    if feature == .reftable, initialized.exitCode == 129 { return false }
    guard initialized.exitCode == 0 else {
        throw GitError.commandFailed("Could not probe this Git version's optional ref support.")
    }
    if feature == .reftable { return true }
    let help = try await runner.run(
        executable: "git", arguments: ["worktree", "add", "-h"], directory: directory, timeout: 10,
        outputLimit: 64 * 1_024)
    guard help.exitCode == 0 || help.exitCode == 129 else {
        throw GitError.commandFailed("Could not probe Git's relative worktree support.")
    }
    return String(decoding: help.stdout + help.stderr, as: UTF8.self).contains("relative-paths")
}

actor ReferenceGateRunner: CommandRunning {
    let runner = CommandRunner()
    private var paused = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?
    private(set) var renameCalls = 0
    func run(
        executable: String, arguments: [String], directory: URL?, timeout: TimeInterval, outputLimit: Int
    ) async throws -> CommandResult {
        if arguments.contains("--move") { renameCalls += 1 }
        if arguments.contains("switch"), !paused {
            paused = true
            for waiter in pauseWaiters { waiter.resume() }
            pauseWaiters.removeAll()
            await withCheckedContinuation { release = $0 }
        }
        return try await runner.run(
            executable: executable, arguments: arguments, directory: directory, timeout: timeout,
            outputLimit: outputLimit)
    }
    func waitForPause() async { if !paused { await withCheckedContinuation { pauseWaiters.append($0) } } }
    func resume() {
        release?.resume()
        release = nil
    }
}

actor TagReplacementRunner: CommandRunning {
    let runner = CommandRunner()
    let replacement: String
    private(set) var deletionArguments: [String]?
    init(replacement: String) { self.replacement = replacement }
    func run(
        executable: String, arguments: [String], directory: URL?, timeout: TimeInterval, outputLimit: Int
    ) async throws -> CommandResult {
        if arguments.contains("update-ref"), arguments.contains("-d"), let index = arguments.firstIndex(of: "-d") {
            deletionArguments = arguments
            let update = try await runner.run(
                executable: "git", arguments: ["update-ref", arguments[index + 1], replacement], directory: directory,
                timeout: timeout, outputLimit: outputLimit)
            guard update.exitCode == 0 else { throw GitError.commandFailed("Fixture replacement failed") }
        }
        return try await runner.run(
            executable: executable, arguments: arguments, directory: directory, timeout: timeout,
            outputLimit: outputLimit)
    }
}

/// Simulate an older system Git's unsupported option; every ordinary command
/// still executes against a real temporary repository.
actor LegacyReferenceRunner: CommandRunning {
    let runner = CommandRunner()
    private(set) var probes = 0
    private(set) var unsupportedFlags = 0
    private(set) var objectCommands = 0
    func run(
        executable: String, arguments: [String], directory: URL?, timeout: TimeInterval, outputLimit: Int
    ) async throws -> CommandResult {
        if arguments.contains("--no-lazy-fetch") {
            if arguments.contains("--version") { probes += 1 } else { unsupportedFlags += 1 }
            return CommandResult(stdout: Data(), stderr: Data("unknown option: --no-lazy-fetch\n".utf8), exitCode: 129)
        }
        if arguments.contains("for-each-ref") || arguments.contains("cat-file") || arguments.contains("merge-base") {
            objectCommands += 1
        }
        return try await runner.run(
            executable: executable, arguments: arguments, directory: directory, timeout: timeout,
            outputLimit: outputLimit)
    }
}
