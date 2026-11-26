import Foundation
import Testing

@testable import GitaCore

@Suite struct ActionsToolsCustomActionsTests {
    @Test func scopeSymbols() {
        let symbols: [CustomActionScope: String] = [
            .repository: "folder", .commit: "circle.inset.filled", .branch: "arrow.triangle.branch",
            .file: "doc", .worktree: "folder.badge.gearshape",
        ]
        #expect(Set(symbols.keys) == Set(CustomActionScope.allCases))
        for (scope, symbol) in symbols {
            #expect(scope.symbolName == symbol)
        }
    }

    @Test func resolvesOriginalTokensOnlyAndAbsolutizesFile() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "repo-root")
        let branch = "$SHA $(id); rm -rf /"
        let branchContext = CustomActionContext(
            repositoryRoot: root, branch: branch, remoteURL: "https://alice:secret@example.com/owner/repo.git")
        let branchAction = CustomAction(
            name: "Branch", scope: .branch, executable: "tool",
            arguments: ["--branch=$BRANCH", "$REPO_ROOT", "$REMOTE_URL", "$BRANCH_EXTRA", ""])
        let branchCmd = try CustomActionRunner().resolve(branchAction, context: branchContext)
        #expect(
            branchCmd.arguments == [
                "--branch=" + branch, root.path, "https://alice:secret@example.com/owner/repo.git", "$BRANCH_EXTRA", "",
            ])
        #expect(!branchCmd.displayCommand.contains("secret"))
        #expect(branchCmd.displayCommand.contains("https://example.com/owner/repo.git"))

        let file = "--output=pwned $(whoami) $REPO_ROOT.txt"
        let fileContext = CustomActionContext(repositoryRoot: root, filePath: file)
        let fileAction = CustomAction(
            name: "File", scope: .file, executable: "tool", arguments: ["$FILE"], workingDirectory: "/tmp")
        let fileCmd = try CustomActionRunner().resolve(fileAction, context: fileContext)
        #expect(fileCmd.arguments == [root.appending(path: file).standardizedFileURL.path])
        #expect(fileCmd.arguments[0].hasPrefix("/"))
        #expect(!fileCmd.arguments[0].hasPrefix("-"))
    }

    @Test func rejectsShellWrappersVersionedSymlinksAndInlineCode() throws {
        let root = FileManager.default.temporaryDirectory
        let context = CustomActionContext(
            repositoryRoot: root, commitSHA: "abc123", branch: "main", filePath: "file.txt")
        for shell in ["/bin/sh", "zsh", "zsh-5.9", "bash5", "dash", "ksh", "csh", "tcsh", "fish", "script"] {
            let action = CustomAction(name: "Shell", executable: shell, arguments: ["-c", "echo"])
            #expect(throws: CustomActionError.shellCommand) {
                try CustomActionRunner().resolve(action, context: context)
            }
        }
        let wrappers: [(String, [String])] = [
            ("/usr/bin/env", ["sh", "-c", "echo"]),
            ("/usr/bin/env", ["-i", "X=1", "/bin/zsh", "-lc", "echo"]),
            ("/usr/bin/env", ["-S", "sh -c echo"]),
            ("/usr/bin/arch", ["-arm64", "/bin/sh", "-c", "echo"]),
            ("/usr/bin/nice", ["-n", "5", "zsh-5.9", "-c", "echo"]),
            ("/usr/bin/nohup", ["/bin/bash", "-c", "echo"]),
            ("/usr/bin/time", ["-p", "sh", "-c", "echo"]),
            ("/usr/bin/caffeinate", ["-i", "zsh"]),
            ("/usr/bin/xargs", ["-n", "1", "sh"]),
            ("/usr/bin/timeout", ["--signal", "KILL", "5", "/bin/bash", "-c", "-x", "echo"]),
            ("/usr/bin/time", ["-o", "/tmp/out", "/bin/sh", "-c", "echo"]),
            ("/usr/bin/sudo", ["-s"]),
            ("/usr/bin/sudo", ["-i"]),
        ]
        for (executable, arguments) in wrappers {
            let action = CustomAction(name: "Wrapped", executable: executable, arguments: arguments)
            #expect(throws: CustomActionError.shellCommand) {
                try CustomActionRunner().resolve(action, context: context)
            }
        }
        let tempDir = root.appending(path: "gita-symlink-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let link = tempDir.appending(path: "innocent-tool")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/bin/sh")
        #expect(throws: CustomActionError.shellCommand) {
            try CustomActionRunner().resolve(
                CustomAction(name: "Link", executable: link.path, arguments: ["-c", "echo"]), context: context)
        }
        let inlineActions = [
            CustomAction(name: "Py", scope: .branch, executable: "python3", arguments: ["-c", "print('$BRANCH')"]),
            CustomAction(name: "PyFlag", scope: .branch, executable: "python3", arguments: ["-c", "-x", "$BRANCH"]),
            CustomAction(name: "Perl", scope: .branch, executable: "perl", arguments: ["-pe", "s/x/$BRANCH/"]),
            CustomAction(name: "OSA", scope: .file, executable: "osascript", arguments: ["-e", "log \"$FILE\""]),
            CustomAction(name: "Node", scope: .commit, executable: "node", arguments: ["--eval=console.log('$SHA')"]),
        ]
        for action in inlineActions {
            #expect(throws: CustomActionError.shellCommand) {
                try CustomActionRunner().resolve(action, context: context)
            }
        }
    }

    @Test func enforcesScopeAndValidatesReferences() throws {
        let root = FileManager.default.temporaryDirectory
        #expect(throws: CustomActionError.unsupportedPlaceholder("$SHA", scope: .repository)) {
            try CustomActionStore.validate(
                CustomAction(name: "Wrong", scope: .repository, executable: "echo", arguments: ["$SHA"]))
        }
        #expect(throws: CustomActionError.unsupportedPlaceholder("$FILE", scope: .branch)) {
            try CustomActionStore.validate(
                CustomAction(name: "Wrong", scope: .branch, executable: "echo", arguments: ["$FILE"]))
        }
        let badBranch = CustomActionContext(repositoryRoot: root, branch: "--upload-pack=evil")
        #expect(throws: CustomActionError.invalidArgument) {
            try CustomActionRunner().resolve(
                CustomAction(name: "Branch", scope: .branch, executable: "git", arguments: ["log", "$BRANCH"]),
                context: badBranch)
        }
        for path in ["", "bad\0path", "bad\npath"] {
            #expect(throws: CustomActionError.invalidExecutable) {
                try CustomActionStore.validate(CustomAction(name: "Bad", executable: path))
            }
        }
        let missingBranch = CustomAction(name: "Branch", scope: .branch, executable: "echo", arguments: ["$BRANCH"])
        #expect(throws: CustomActionError.missingPlaceholder("$BRANCH")) {
            try CustomActionRunner().resolve(missingBranch, context: CustomActionContext(repositoryRoot: root))
        }
    }

    @Test func storeLenientLoadAndHardenedCollidingImport() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "actions.json")
        let store = CustomActionStore(fileURL: file)
        #expect(try store.load().isEmpty)

        var existing = CustomAction(name: "Safe", scope: .branch, executable: "echo", arguments: ["$BRANCH"])
        existing.confirmsBeforeRun = false
        _ = try store.upsert(existing)

        var colliding = existing
        colliding.executable = "/usr/bin/true"
        colliding.confirmsBeforeRun = false
        let payload = try store.exportJSON([colliding])
        let imported = try store.importJSON(payload)
        #expect(imported.count == 1)
        #expect(imported[0].executable == "/usr/bin/true")
        #expect(imported[0].confirmsBeforeRun == true)

        // One broken or future-schema entry on disk must not brick load/delete of the library.
        let brokenJSON = """
            [{"id":"\(UUID().uuidString)","name":"Broken","scope":"repository","executable":"/bin/sh","arguments":["-c","id"]},
             {"id":"\(UUID().uuidString)","name":"Future","scope":"future_scope","executable":"/bin/echo","arguments":[]},
             {"id":"\(existing.id.uuidString)","name":"Valid","scope":"repository","executable":"/bin/echo","arguments":["$REPO_ROOT"]}]
            """
        try Data(brokenJSON.utf8).write(to: file, options: .atomic)
        let loaded = try store.load()
        #expect(loaded.count == 2)
        #expect(try store.delete(id: loaded[0].id).count == 1)
    }

    @Test func executesArgvAndReportsBothStreams() async throws {
        let mock = ActionCommandRecorder()
        let root = FileManager.default.temporaryDirectory
        let action = CustomAction(name: "Inspect", scope: .file, executable: "/bin/echo", arguments: ["$FILE"])
        let context = CustomActionContext(repositoryRoot: root, filePath: "$(whoami) ; \u{0060}id\u{0060}")
        let output = try await CustomActionRunner(runner: mock).run(action, context: context)
        let request = try #require(await mock.request)
        #expect(request.executable == action.executable)
        #expect(request.arguments == [root.appending(path: "$(whoami) ; `id`").standardizedFileURL.path])
        #expect(request.directory == root)
        #expect(request.timeout == 60)
        #expect(output.stdout == "one" && output.stderr == "two")
        #expect(output.exitCode == 7 && !output.succeeded && output.duration >= 0)
        #expect(CustomActionRunState.running(command: output.command).isRunning)
        #expect(CustomActionRunState.finished(output).output == output)
        #expect(CustomActionRunState.failed("failed").errorMessage == "failed")
    }
}

private actor ActionCommandRecorder: CommandRunning {
    var request: CommandRequest?
    func run(
        executable: String, arguments: [String], directory: URL?, timeout: TimeInterval,
        outputLimit: Int
    ) async throws -> CommandResult {
        request = CommandRequest(
            executable: executable, arguments: arguments, directory: directory, timeout: timeout,
            outputLimit: outputLimit)
        return CommandResult(stdout: Data("one".utf8), stderr: Data("two".utf8), exitCode: 7)
    }
}
