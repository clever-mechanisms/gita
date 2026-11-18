import Foundation
import Testing

@testable import GitaCore

private struct WorkflowFixture {
    let container: URL
    let root: URL
    let service: GitService
    let runner = CommandRunner()

    init() async throws {
        container = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GitaWorkflows-" + UUID().uuidString, isDirectory: true)
        root = container.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        service = GitService(root: root)
        try await git(["init", "--initial-branch=main", "--template="])
        try await git(["config", "user.name", "Workflow Tester"])
        try await git(["config", "user.email", "workflows@example.invalid"])
        try await git(["config", "commit.gpgsign", "false"])
        try await git(["config", "core.hooksPath", "/dev/null"])
    }

    func remove() { try? FileManager.default.removeItem(at: container) }

    func write(_ path: String, _ contents: String) throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
    }

    @discardableResult func git(_ arguments: [String]) async throws -> CommandResult {
        let output = try await runner.run(
            executable: "git", arguments: arguments, directory: root, timeout: 10, outputLimit: 4 * 1_024 * 1_024)
        guard output.exitCode == 0 else { throw GitError.commandFailed(String(decoding: output.stderr, as: UTF8.self)) }
        return output
    }

    @discardableResult func commit(_ message: String, author: String? = nil) async throws -> String {
        try await git(["add", "--all"])
        try await git(["commit", "-m", message] + (author.map { ["--author=" + $0] } ?? []))
        return try await git(["rev-parse", "HEAD"]).text.trimmingCharacters(in: .newlines)
    }
}

private actor AcquisitionRecorder: CommandRunning {
    private(set) var commands: [[String]] = []
    let result: CommandResult
    init(result: CommandResult = CommandResult(stdout: Data(), stderr: Data(), exitCode: 0)) { self.result = result }
    func run(
        executable _: String, arguments: [String], directory _: URL?, timeout _: TimeInterval, outputLimit _: Int
    ) async throws -> CommandResult {
        commands.append(arguments)
        return result
    }
}

private actor GatedWorkflowRunner: CommandRunning {
    private let runner = CommandRunner()
    private var release: CheckedContinuation<Void, Never>?
    private(set) var blocked = false
    private(set) var diffReads = 0
    private(set) var patchPaths: [String] = []
    private(set) var patchDirectoryModes: [Int] = []
    let gateStage: Bool
    init(gateStage: Bool = false) { self.gateStage = gateStage }

    func run(
        executable: String, arguments: [String], directory: URL?, timeout: TimeInterval, outputLimit: Int
    ) async throws -> CommandResult {
        if gateStage, arguments.contains("add") {
            blocked = true
            await withCheckedContinuation { release = $0 }
        }
        if arguments.contains("diff") { diffReads += 1 }
        if arguments.contains("apply"), let path = arguments.last {
            patchPaths.append(path)
            let attributes = try FileManager.default.attributesOfItem(
                atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path)
            patchDirectoryModes.append(attributes[.posixPermissions] as? Int ?? 0)
        }
        return try await runner.run(
            executable: executable, arguments: arguments, directory: directory, timeout: timeout,
            outputLimit: outputLimit)
    }

    func resume() {
        release?.resume()
        release = nil
    }
}

@Suite(.serialized)
struct RepositoryWorkflowTests {
    @Test func searchWalksAllHistoryAndPagesLiteralMatches() async throws {
        let fixture = try await WorkflowFixture()
        defer { fixture.remove() }
        try fixture.write("*.txt", "First\n")
        let first = try await fixture.commit(
            "Needle[.*] first\n\nMultiline Needle\nnext line", author: "Special [.*] Author <Special@example.invalid>")
        try fixture.write("other.txt", "Second\n")
        let second = try await fixture.commit("NEEDLE[.*] second\n\nMultiline Needle\nnot adjacent\nnext line")
        try fixture.write("*.txt", "Third\n")
        let third = try await fixture.commit("Newest unrelated commit")
        #expect(try await fixture.service.snapshot(limit: 1).commits.map(\.id) == [third])
        #expect(
            try await fixture.service.searchHistory(query: "needle[.*]", field: .message).map(\.id) == [second, first])
        #expect(
            try await fixture.service.searchHistory(query: "needle[.*]", field: .message, limit: 1).map(\.id) == [
                second
            ])
        #expect(
            try await fixture.service.searchHistory(query: "needle[.*]", field: .message, limit: 1, skip: 1).map(\.id)
                == [first])
        #expect(
            try await fixture.service.searchHistory(query: "needle[.*]", field: .message, limit: 1, skip: 2).isEmpty)
        #expect(try await fixture.service.searchHistory(query: "needle.*", field: .message).isEmpty)
        #expect(try await fixture.service.searchHistory(query: "[.*] aUtHoR", field: .author).map(\.id) == [first])
        #expect(try await fixture.service.searchHistory(query: "special@EXAMPLE", field: .author).map(\.id) == [first])
        #expect(try await fixture.service.searchHistory(query: "*.txt", field: .path).map(\.id) == [third, first])
        #expect(
            try await fixture.service.searchHistory(query: "*.txt", field: .path, limit: 1, skip: 1).map(\.id) == [
                first
            ])
        #expect(
            try await fixture.service.searchHistory(query: "multiline NEEDLE\nnext line", field: .message).map(\.id)
                == [first])
        #expect(
            try await fixture.service.searchHistory(query: "", field: .message, limit: 1, skip: 1).map(\.id) == [second]
        )
        try await fixture.git(["tag", "-a", "chosen", first, "-m", "Annotated tag"])
        #expect(try await fixture.service.searchHistory(query: "chosen", field: .commit).map(\.id) == [first])
        #expect(
            try await fixture.service.searchHistory(query: String(first.prefix(12)), field: .commit).map(\.id) == [
                first
            ])
        #expect(try await fixture.service.searchHistory(query: "chosen", field: .commit, skip: 1).isEmpty)
        await #expect(throws: GitError.self) { try await fixture.service.searchHistory(query: "--all", field: .commit) }
        await #expect(throws: GitError.self) {
            try await fixture.service.searchHistory(query: "../outside", field: .path)
        }
        await #expect(throws: CommandError.self) {
            try await fixture.service.searchHistory(query: "bad\0query", field: .message)
        }
    }

    @Test func commitDetailsAndComparisonsRespectEveryMergeParentAndLiteralPaths() async throws {
        let fixture = try await WorkflowFixture()
        defer { fixture.remove() }
        try fixture.write("base.txt", "Base\n")
        let initial = try await fixture.commit(
            "Subject\n\nFull body [literal].\nSecond body line.", author: "Original Author <original@example.invalid>")
        let details = try await fixture.service.commitDetails(ref: initial)
        #expect(details.commit.id == initial)
        #expect(details.commit.author == "Original Author")
        #expect(details.commit.email == "original@example.invalid")
        #expect(details.commit.parents.isEmpty)
        #expect(details.message == "Subject\n\nFull body [literal].\nSecond body line.\n")
        #expect(details.committer == "Workflow Tester")
        try await fixture.git(["switch", "-c", "feature"])
        try fixture.write(":(glob)*\nfeature.txt", "Feature content\n")
        let feature = try await fixture.commit("Feature")
        try await fixture.git(["switch", "main"])
        try fixture.write("main.txt", "Main content\n")
        let main = try await fixture.commit("Main")
        try await fixture.git(["merge", "--no-ff", "feature", "-m", "Merge feature\n\nBoth parents retained."])
        let merge = try await fixture.service.commitDetails(ref: "HEAD")
        #expect(merge.commit.parents == [main, feature])
        #expect(merge.message.contains("Both parents retained."))
        #expect(
            try await fixture.service.compareFiles(base: main, head: merge.commit.id).map(\.path) == [
                ":(glob)*\nfeature.txt"
            ])
        #expect(
            try await fixture.service.compareFiles(base: feature, head: merge.commit.id).map(\.path) == ["main.txt"])
        let diff = try await fixture.service.compareDiff(
            base: initial, head: merge.commit.id, path: ":(glob)*\nfeature.txt")
        #expect(diff.contains("+Feature content"))
        #expect(!diff.contains("+Main content"))
        #expect(try await fixture.service.compareFiles(base: "HEAD", head: "HEAD").isEmpty)
        await #expect(throws: GitError.self) {
            try await fixture.service.compareDiff(base: "--output=bad", head: "HEAD", path: nil)
        }
        let blob = try await fixture.git(["rev-parse", "HEAD:base.txt"]).text.trimmingCharacters(in: .newlines)
        await #expect(throws: GitError.self) { try await fixture.service.compareFiles(base: blob, head: "HEAD") }
        await #expect(throws: GitError.self) { try await fixture.service.searchHistory(query: blob, field: .commit) }
    }

    @Test func initializeClaimsANewFolderAndRefusesExistingFilesAndSymlinks() async throws {
        let fixture = try await WorkflowFixture()
        defer { fixture.remove() }
        let destination = fixture.container.appendingPathComponent("new repository\nname")
        let initialized = try await GitService.initialize(at: destination, branch: "topic/start")
        let state = try await GitService(root: initialized).snapshot()
        #expect(initialized == destination.resolvingSymlinksInPath())
        #expect(state.branch == "topic/start")
        #expect(state.commits.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: initialized.appendingPathComponent(".git/hooks").path))
        let marker = destination.appendingPathComponent("preserve.txt")
        try Data("Keep this".utf8).write(to: marker)
        await #expect(throws: GitError.self) { try await GitService.initialize(at: destination) }
        #expect(try String(contentsOf: marker, encoding: .utf8) == "Keep this")
        let existingFile = fixture.container.appendingPathComponent("existing-file")
        try Data("Keep file".utf8).write(to: existingFile)
        await #expect(throws: GitError.self) { try await GitService.initialize(at: existingFile) }
        #expect(try String(contentsOf: existingFile, encoding: .utf8) == "Keep file")
        let link = fixture.container.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        await #expect(throws: GitError.self) { try await GitService.initialize(at: link) }
        let dangling = fixture.container.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(
            at: dangling, withDestinationURL: fixture.container.appendingPathComponent("absent"))
        await #expect(throws: GitError.self) { try await GitService.initialize(at: dangling) }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: dangling.path).hasSuffix("absent"))
        let badBranch = fixture.container.appendingPathComponent("bad-branch")
        await #expect(throws: GitError.self) { try await GitService.initialize(at: badBranch, branch: "bad..branch") }
        #expect(!FileManager.default.fileExists(atPath: badBranch.path))
    }

    @Test func cloneUsesLocalFixturesAndNeverReusesAnExistingDestination() async throws {
        let fixture = try await WorkflowFixture()
        defer { fixture.remove() }
        try fixture.write("README.md", "Clone fixture\n")
        let head = try await fixture.commit("Clone source")
        for (name, remote) in [("path clone", fixture.root.path), ("URL clone", fixture.root.absoluteString)] {
            let target = fixture.container.appendingPathComponent(name)
            let cloned = try await GitService.clone(remote: remote, to: target)
            #expect(try await GitService(root: cloned).snapshot().head == head)
            #expect(
                try String(contentsOf: cloned.appendingPathComponent("README.md"), encoding: .utf8) == "Clone fixture\n"
            )
            await #expect(throws: GitError.self) { try await GitService.clone(remote: remote, to: target) }
            #expect(try await GitService(root: cloned).snapshot().head == head)
        }
        let failed = fixture.container.appendingPathComponent("failed-clone")
        await #expect(throws: GitError.self) {
            try await GitService.clone(
                remote: fixture.container.appendingPathComponent("missing-source").path, to: failed)
        }
        #expect(FileManager.default.fileExists(atPath: failed.path))
        #expect(try await fixture.service.snapshot().head == head)
    }

    @Test func acquisitionRejectsUnsafeRemotesBeforeCreatingAnything() async throws {
        let fixture = try await WorkflowFixture()
        defer { fixture.remove() }
        let recorder = AcquisitionRecorder()
        let remotes = [
            "ext::sh -c something", "helper::path", "http://example.invalid/repo", "ftp://example.invalid/repo",
            "https://user:secret@example.invalid/repo", "https://user@example.invalid/repo",
            "https://example.invalid/repo?token=secret",
            "ssh://git:secret@example.invalid/repo", "ssh://-option/repo", "file://foreign-host/repo",
            "file:///tmp/bad%00name",
            "--upload-pack=bad", "./relative", "../relative", "", "host:", "host::helper", "bad\nsource",
        ]
        for (index, remote) in remotes.enumerated() {
            let destination = fixture.container.appendingPathComponent("refused-\(index)")
            await #expect(throws: GitError.self) {
                try await GitService.clone(remote: remote, to: destination, runner: recorder)
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
        #expect(await recorder.commands.isEmpty)
        for (index, remote) in [
            "https://example.invalid/repo.git", "ssh://git@example.invalid:2222/team/repo.git",
            "git@example.invalid:team/repo.git", "[::1]:repo",
        ].enumerated() {
            _ = try await GitService.clone(
                remote: remote, to: fixture.container.appendingPathComponent("allowed-\(index)"), runner: recorder)
        }
        let commands = await recorder.commands
        #expect(commands.count == 4)
        #expect(
            commands.allSatisfy {
                $0.contains("protocol.allow=never") && $0.contains("protocol.ext.allow=never")
                    && $0.contains("--no-local")
            })
    }

    @Test func acquisitionFailuresRedactCredentialsAndDoNotCleanUpFolders() async throws {
        let fixture = try await WorkflowFixture()
        defer { fixture.remove() }
        let destination = fixture.container.appendingPathComponent("failed")
        let recorder = AcquisitionRecorder(
            result: CommandResult(
                stdout: Data(), stderr: Data("failed https://user:secret@example.invalid/repo".utf8), exitCode: 1))
        do {
            _ = try await GitService.clone(remote: "https://example.invalid/repo", to: destination, runner: recorder)
            Issue.record("Clone should have failed")
        } catch {
            #expect(!error.localizedDescription.contains("secret"))
            #expect(!error.localizedDescription.contains("user:"))
        }
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func hunkStageAndUnstagePreserveWorkingFilesAndOtherHunks() async throws {
        let fixture = try await WorkflowFixture()
        defer { fixture.remove() }
        let path = "*.txt"
        let baseline = (1...40).map { "Line \($0)\n" }.joined()
        try fixture.write(path, baseline)
        try await fixture.commit("Hunk baseline")
        let modified = baseline.replacingOccurrences(of: "Line 2\n", with: "First changed\nInserted line\n")
            .replacingOccurrences(of: "Line 32\n", with: "Second changed\n")
        try fixture.write(path, modified)
        let recorder = GatedWorkflowRunner()
        let service = GitService(root: fixture.root, runner: recorder)
        let diff = try await service.diff(path: path)
        #expect(UnifiedDiff.parse(diff).hunks.count == 2)
        try await service.applyHunk(path: path, staged: false, expectedDiff: diff, hunkIndex: 1)
        let indexed = try await fixture.git(["show", ":" + path]).text
        #expect(indexed == baseline.replacingOccurrences(of: "Line 32\n", with: "Second changed\n"))
        #expect(try String(contentsOf: fixture.root.appendingPathComponent(path), encoding: .utf8) == modified)
        let staged = try await service.diff(path: path, staged: true)
        try await service.applyHunk(path: path, staged: true, expectedDiff: staged, hunkIndex: 0)
        #expect(try await fixture.git(["show", ":" + path]).text == baseline)
        #expect(try String(contentsOf: fixture.root.appendingPathComponent(path), encoding: .utf8) == modified)
        #expect(await recorder.patchPaths.count == 4) // check/apply for each operation
        #expect(await recorder.patchDirectoryModes.allSatisfy { $0 == 0o700 })
        for patch in await recorder.patchPaths {
            #expect(
                !FileManager.default.fileExists(atPath: URL(fileURLWithPath: patch).deletingLastPathComponent().path))
        }
    }

    @Test func hunkApplicationRefusesStaleBytesAndUnsupportedChanges() async throws {
        let fixture = try await WorkflowFixture()
        defer { fixture.remove() }
        try fixture.write("text.txt", "Original\n")
        try fixture.write("binary.bin", "Initial binary placeholder\n")
        try await fixture.commit("Baseline")
        try fixture.write("text.txt", "Café\n")
        let current = try await fixture.service.diff(path: "text.txt")
        let normalizedDifferently = current.replacingOccurrences(of: "Café", with: "Cafe\u{301}")
        #expect(current == normalizedDifferently)
        #expect(!current.utf8.elementsEqual(normalizedDifferently.utf8))
        do {
            try await fixture.service.applyHunk(
                path: "text.txt", staged: false, expectedDiff: normalizedDifferently, hunkIndex: 0)
            Issue.record("Canonically equivalent but different bytes must be stale")
        } catch GitError.staleDiff {} catch { throw error }
        try fixture.write("text.txt", "Changed again\n")
        do {
            try await fixture.service.applyHunk(path: "text.txt", staged: false, expectedDiff: current, hunkIndex: 0)
            Issue.record("Changed worktree must make the old review stale")
        } catch GitError.staleDiff {} catch { throw error }
        let fresh = try await fixture.service.diff(path: "text.txt")
        await #expect(throws: GitError.self) {
            try await fixture.service.applyHunk(path: "text.txt", staged: false, expectedDiff: fresh, hunkIndex: -1)
        }
        try fixture.write("new.txt", "New\n")
        let newDiff = try await fixture.service.diff(path: "new.txt")
        await #expect(throws: GitError.self) {
            try await fixture.service.applyHunk(path: "new.txt", staged: false, expectedDiff: newDiff, hunkIndex: 0)
        }
        try Data([0, 1, 2, 0, 3]).write(to: fixture.root.appendingPathComponent("binary.bin"))
        let binary = try await fixture.service.diff(path: "binary.bin")
        await #expect(throws: GitError.self) {
            try await fixture.service.applyHunk(path: "binary.bin", staged: false, expectedDiff: binary, hunkIndex: 0)
        }
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("text.txt"))
        let deleted = try await fixture.service.diff(path: "text.txt")
        await #expect(throws: GitError.self) {
            try await fixture.service.applyHunk(path: "text.txt", staged: false, expectedDiff: deleted, hunkIndex: 0)
        }
        #expect(try await fixture.service.diff(path: nil, staged: true).isEmpty)
    }

    @Test func queuedHunkReadsTheDiffAfterThePrecedingMutation() async throws {
        let fixture = try await WorkflowFixture()
        defer { fixture.remove() }
        try fixture.write("file.txt", "Original\n")
        try await fixture.commit("Baseline")
        try fixture.write("file.txt", "Changed\n")
        let reviewed = try await fixture.service.diff(path: "file.txt")
        let recorder = GatedWorkflowRunner(gateStage: true)
        let service = GitService(root: fixture.root, runner: recorder)
        let staging = Task { try await service.stage(paths: ["file.txt"]) }
        defer { Task { await recorder.resume() } }
        for _ in 0..<100 {
            if await recorder.blocked { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await recorder.blocked)
        let hunk = Task {
            try await service.applyHunk(path: "file.txt", staged: false, expectedDiff: reviewed, hunkIndex: 0)
        }
        try await Task.sleep(for: .milliseconds(40))
        #expect(await recorder.diffReads == 0)
        await recorder.resume()
        try await staging.value
        do {
            try await hunk.value
            Issue.record("The preceding stage makes the unstaged review stale")
        } catch GitError.staleDiff {} catch { throw error }
        #expect(await recorder.patchPaths.isEmpty)
        #expect(try await fixture.git(["show", ":file.txt"]).text == "Changed\n")
    }
}
