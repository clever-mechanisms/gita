import Foundation
import Testing

@testable import GitaCore

@Suite struct PrePushFlightCheckServiceTests {
    @MainActor @Test func validatedArgvAndSettings() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = FlightCheckSettingsStore(defaults: defaults)
        let root = URL(fileURLWithPath: "/tmp/project")
        for executable in ["", "  ", "swift test", "foo\0bar", "swift;ls"] {
            #expect(throws: ControlPlaneError.self) {
                try store.save(.init(executable: executable, arguments: []), for: root)
            }
        }
        for bad in [
            FlightCheckCommand(executable: "/bin/sh", arguments: ["-lc", "true"]),
            .init(executable: "swift", arguments: ["test\0"]),
            .init(executable: "swift", arguments: [], timeoutSeconds: 0),
        ] {
            #expect(throws: ControlPlaneError.self) { try bad.validate() }
        }
        let argv = FlightCheckCommand(executable: "tool", arguments: ["one arg", "$literal", ""], timeoutSeconds: 60)
        try store.save(argv, for: root)
        #expect(FlightCheckSettingsStore(defaults: defaults).command(for: root.appendingPathComponent(".")) == argv)
        try store.save(nil, for: root)
        #expect(store.command(for: root) == nil)
    }

    @Test func detachedShadowReusesSHAAndCleansPassAndFailure() async throws {
        let repo = try await OperationFixture()
        defer { repo.remove() }
        try repo.write("tracked", "committed\n")
        try repo.write(
            "check",
            """
            #!/bin/sh
            pwd
            git symbolic-ref -q HEAD && exit 8
                git worktree lock . || exit 9
            cat tracked
            echo changed > tracked
            echo TOKEN=secret
            exit "$1"
            """)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: repo.root.appendingPathComponent("check").path)
        let sha = try await repo.commit("Fixture")
        try repo.write("tracked", "precious edits\n")
        let service = PrePushFlightCheckService()
        for status in [0, 7] {
            let command = FlightCheckCommand(executable: "./check", arguments: [String(status)])
            let run = await service.run(gitService: repo.service, command: command)
            let value: FlightCheckResult
            switch run.state {
            case .passed(let result), .failed(let result): value = result
            default:
                Issue.record("Expected a completed check")
                return
            }
            #expect(value.commitSHA == sha)
            #expect(run.state == (status == 0 ? .passed(value) : .failed(value)))
            #expect(value.exitCode == Int32(status) && !run.cached)
            #expect(value.output.lines.contains("committed") && value.output.lines.contains("TOKEN=••••"))
            let shadow = try #require(value.output.lines.first)
            #expect(shadow.contains("GitaFlightCheck-") && !FileManager.default.fileExists(atPath: shadow))
            let cached = await service.run(gitService: repo.service, command: command)
            #expect(cached.cached && cached.state == run.state)
            let fresh = await service.run(gitService: repo.service, command: command, force: true)
            #expect(!fresh.cached && fresh.state != run.state)
        }
        #expect(
            try String(contentsOf: repo.root.appendingPathComponent("tracked"), encoding: .utf8) == "precious edits\n")
        #expect(
            try await repo.git(["worktree", "list", "--porcelain"]).text.components(separatedBy: "worktree ").count == 2
        )
    }

    @Test func cancellationAndTimeoutRemoveCheckoutBeforeReturning() async throws {
        let repo = try await OperationFixture()
        defer { repo.remove() }
        try repo.write("wait.sh", "pwd > \"$1\"\necho started\nsleep 20\n")
        try await repo.commit("Wait")
        let service = PrePushFlightCheckService()
        let receipt = repo.container.appendingPathComponent("shadow-path")
        for cancel in [true, false] {
            let command = FlightCheckCommand(
                executable: "/bin/sh", arguments: ["wait.sh", receipt.path], timeoutSeconds: cancel ? 5 : 0.4)
            let (started, continuation) = AsyncStream<Void>.makeStream()
            let task = Task {
                defer { continuation.finish() }
                return await service.run(gitService: repo.service, command: command) { state in
                    if case .running(_, _, let tail) = state, tail.lines.contains("started") {
                        continuation.yield(())
                    }
                }
            }
            if cancel {
                var iterator = started.makeAsyncIterator()
                _ = await iterator.next()
                task.cancel()
            }
            let run = await task.value
            if cancel {
                #expect(run.state == .cancelled)
            } else if case .error = run.state {
            } else {
                Issue.record("Expected timeout")
            }
            let path = try String(contentsOf: receipt, encoding: .utf8).trimmingCharacters(in: .newlines)
            #expect(path.contains("GitaFlightCheck-") && !FileManager.default.fileExists(atPath: path))
            #expect(
                try await repo.git(["worktree", "list", "--porcelain"]).text.components(separatedBy: "worktree ").count
                    == 2)
            try FileManager.default.removeItem(at: receipt)
        }
    }

    @Test func replacementRunWaitsForPreviousCheckoutToBeRemoved() async throws {
        let repo = try await OperationFixture()
        defer { repo.remove() }
        try repo.write("wait.sh", "pwd\nsleep 5\n")
        try await repo.commit("Wait")
        let service = PrePushFlightCheckService()
        let (paths, ready) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let previous = Task {
            defer { ready.finish() }
            return await service.run(gitService: repo.service, command: .init(executable: "sh", arguments: ["wait.sh"]))
            { state in
                if case .running(_, _, let output) = state, let first = output.lines.first { ready.yield(first) }
            }
        }
        var iterator = paths.makeAsyncIterator()
        let path = try #require(await iterator.next())
        let next = await service.run(gitService: repo.service, command: .init(executable: "pwd", arguments: [])) {
            state in
            if case .preparing = state { #expect(!FileManager.default.fileExists(atPath: path)) }
        }
        #expect(await previous.value.state == .cancelled)
        guard case .passed = next.state else {
            Issue.record("Replacement check did not pass")
            return
        }
    }

    @Test func outputBoundsAndRedaction() {
        var output = FlightCheckOutput()
        output.append(String(repeating: "line\n", count: 400) + "\u{1b}[31mPASSWORD=secret\n")
        #expect(output.wasTruncated && output.lines.count == 300)
        #expect(output.lines.last == "PASSWORD=••••")
        output.append(String(repeating: "€", count: 32_768))
        #expect(output.text.utf8.count <= 32_768 && !output.text.contains("\u{fffd}"))
    }
}
