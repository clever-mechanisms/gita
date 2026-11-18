import Darwin
import Foundation
import Testing

@testable import GitaCore

struct OperationFixture {
    let container: URL
    let root: URL
    let service: GitService
    let runner = CommandRunner()
    init() async throws {
        container = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GitaOperations-" + UUID().uuidString)
        root = container.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        service = GitService(root: root)
        try await git(["init", "--initial-branch=main", "--template="])
        try await git(["config", "user.name", "Git Operation Tests"])
        try await git(["config", "user.email", "operations@example.invalid"])
        try await git(["config", "commit.gpgsign", "false"])
        try await git(["config", "core.hooksPath", "/dev/null"])
    }
    func remove() { try? FileManager.default.removeItem(at: container) }
    func write(_ path: String, _ text: String) throws { try write(path, data: Data(text.utf8)) }
    func write(_ path: String, data: Data) throws {
        let target = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target)
    }
    @discardableResult func git(_ arguments: [String], allowFailure: Bool = false) async throws -> CommandResult {
        let result = try await runner.run(
            executable: "git", arguments: arguments, directory: root, timeout: 20, outputLimit: 8 * 1_024 * 1_024)
        if !allowFailure && result.exitCode != 0 {
            throw GitError.commandFailed(String(decoding: result.stderr, as: UTF8.self))
        }
        return result
    }
    @discardableResult func commit(_ message: String) async throws -> String {
        try await git(["add", "--all"])
        try await git(["commit", "-m", message])
        return try await head()
    }
    func head() async throws -> String { try await git(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines) }
    @discardableResult func diverge(
        path: String = "file.txt", base: String = "base\n", ours: String = "current\n", theirs: String = "incoming\n"
    ) async throws -> (current: String, incoming: String) {
        try write(path, base)
        try await commit("Base")
        try await git(["switch", "-c", "incoming"])
        try write(path, theirs)
        let incoming = try await commit("Incoming")
        try await git(["switch", "main"])
        try write(path, ours)
        let current = try await commit("Current")
        return (current, incoming)
    }
}

func stopped(_ outcome: GitOperationOutcome, kind: GitOperationKind) throws -> GitOperationState {
    guard case .stopped(let state, _) = outcome else {
        Issue.record("Expected a stopped \(kind.rawValue)")
        throw GitError.operationChanged
    }
    #expect(state.kind == kind)
    return state
}
func completed(_ outcome: GitOperationOutcome) {
    if case .stopped(let state, let message) = outcome {
        Issue.record("Unexpected \(state.kind.rawValue) stop: \(message)")
    }
}
func expectGitError(_ expected: GitError, _ action: () async throws -> Void) async {
    await expectError(expected, action)
}
/// The action throws an error of the expected type with the expected message.
func expectError(_ expected: any Error, _ action: () async throws -> Void) async {
    do {
        try await action()
        Issue.record("Expected \(expected.localizedDescription)")
    } catch {
        #expect(String(reflecting: type(of: error)) == String(reflecting: type(of: expected)))
        #expect(error.localizedDescription == expected.localizedDescription)
    }
}

actor EditingDuringStageRunner: CommandRunning {
    private let runner = CommandRunner()
    let file: URL
    private(set) var edited = false
    private(set) var savedContents: Data?
    init(file: URL) { self.file = file }
    func run(
        executable: String, arguments: [String], directory: URL?, timeout: TimeInterval, outputLimit: Int
    ) async throws -> CommandResult {
        if !edited, arguments.contains("update-index") || arguments.contains("add") {
            savedContents = try? Data(contentsOf: file)
            try Data("external unreviewed edit\n".utf8).write(to: file)
            edited = true
        }
        return try await runner.run(
            executable: executable, arguments: arguments, directory: directory, timeout: timeout,
            outputLimit: outputLimit)
    }
}
