import Foundation
import Testing

@testable import GitaCore

@Suite struct AgentControlFlightRecorderTests {
    @Test func hooksRequireOptInAndUseOnlySupportedTriggers() async throws {
        try await AgentControlFixture.withRepository { repo in
            let recorder = FlightRecorderService(maxSnapshotsPerKey: 2)
            let key = "../session bad.lock"
            let submit = AgentHookEvent(tool: .claudeCode, event: "UserPromptSubmit", sessionID: key)
            #expect(await !recorder.isEnabled(for: repo.root))
            #expect(try await recorder.handleHookEvent(submit, repositoryRoot: repo.root) == nil)
            await recorder.setEnabled(true, for: repo.root)
            let events = [
                submit, AgentHookEvent(tool: .claudeCode, event: "Stop", sessionID: key),
                AgentHookEvent(tool: .codex, event: "notify", sessionID: key, kind: "agent-turn-complete"),
            ]
            var snapshots: [FlightSnapshot] = []
            for event in events {
                let result = try await recorder.handleHookEvent(event, repositoryRoot: repo.root)
                snapshots.append(try #require(result))
            }
            #expect(snapshots.map(\.trigger) == [.userPromptSubmit, .agentStop, .codexTurnComplete])
            #expect(snapshots.map(\.sequence) == [1, 2, 3])
            #expect(snapshots[0].parentOID == nil)
            #expect(snapshots[1].parentOID == snapshots[0].id)
            #expect(snapshots[2].sessionID == key)
            #expect(snapshots[2].tool == .codex)
            #expect(!snapshots[2].refName.contains(".."))
            let ignored = AgentHookEvent(tool: .codex, event: "notify", kind: "something-else")
            #expect(try await recorder.handleHookEvent(ignored, repositoryRoot: repo.root) == nil)
            #expect(try await recorder.listSnapshots(in: repo.root, key: key) == Array(snapshots.suffix(2).reversed()))
            try await recorder.clearSnapshots(in: repo.root, key: key)
            #expect(try await recorder.listSnapshots(in: repo.root, key: key).isEmpty)
            #expect(!FileManager.default.fileExists(atPath: repo.root.appending(path: ".git/index").path))
        }
    }

    @Test func hooksCaptureTheirLinkedWorktree() async throws {
        try await AgentControlFixture.withRepository { repo in
            try repo.write("file", "main")
            try await repo.commit()
            let sibling = try await repo.sibling()
            try repo.write("file", "linked checkout", in: sibling)
            let recorder = FlightRecorderService()
            await recorder.setEnabled(true, for: repo.root)
            let event = AgentHookEvent(tool: .claudeCode, event: "Stop", sessionID: "s", cwd: sibling.path)
            let captured = try await recorder.handleHookEvent(event, repositoryRoot: repo.root)
            let snapshot = try #require(captured)
            #expect(try await repo.git(["show", snapshot.id + ":file"]) == "linked checkout")
            #expect(try repo.read("file") == "main")
        }
    }

    @Test func concurrentCapturesPreserveBothTurns() async throws {
        try await AgentControlFixture.withRepository { repo in
            let first = FlightRecorderService()
            let second = FlightRecorderService()
            async let a = first.captureSnapshot(in: repo.root, label: "a")
            async let b = second.captureSnapshot(in: repo.root, label: "b")
            let snapshots = try await [a, b]
            let history = try await first.listSnapshots(in: repo.root)
            #expect(Set(history.map(\.id)) == Set(snapshots.map(\.id)))
            #expect(history.map(\.sequence) == [2, 1])
            #expect(history.first?.parentOID == history.last?.id)
        }
    }

    @Test func snapshotsAndDiffsPreserveStagedAndUnstagedState() async throws {
        try await AgentControlFixture.withRepository { repo in
            try repo.write("tracked", "original\n")
            try await repo.commit()
            try repo.write("tracked", "staged\n")
            try await repo.git(["add", "tracked"])
            try repo.write("tracked", "working\n")
            try repo.write("new", "first\n")
            let index = try await repo.index()
            let recorder = FlightRecorderService()
            let first = try await recorder.captureSnapshot(in: repo.root, label: "First\nturn")
            #expect(first.changedFileCount == 2)
            #expect(first.label == "First\nturn")
            try repo.write("new", "second\n")
            let second = try await recorder.captureSnapshot(in: repo.root)
            #expect(try await recorder.listSnapshots(in: repo.root) == [second, first])
            let turns = try await recorder.diff(in: repo.root, from: first.id, to: second.id)
            #expect(turns.fromLabel == first.label)
            #expect(turns.toLabel == second.label)
            #expect(turns.files == ["new"])
            #expect(turns.diffText.contains("+second"))
            try repo.write("later", "untracked\n")
            let working = try await recorder.diff(in: repo.root, from: second.id, to: nil)
            #expect(working.files == ["later"])
            #expect(working.diffText.contains("+untracked"))
            #expect(!working.isTruncated)
            #expect(try await repo.index() == index)
            #expect(try await repo.git(["show", ":tracked"]) == "staged")
            #expect(try repo.read("tracked") == "working\n")
            #expect(try repo.read("new") == "second\n")
        }
    }

    @Test func restoreFilesAndWholeTurnPreserveHeadAndIndex() async throws {
        try await AgentControlFixture.withRepository { repo in
            try repo.write("base", "initial")
            try await repo.commit()
            let head = try await repo.git(["rev-parse", "HEAD"])
            try repo.write("base", "snapshot")
            try repo.write("new", "save me")
            let recorder = FlightRecorderService()
            let snapshot = try await recorder.captureSnapshot(in: repo.root)
            let index = try await repo.index()
            try repo.write("base", "later")
            try FileManager.default.removeItem(at: repo.root.appending(path: "new"))
            try repo.write("extra", "remove me")
            try await recorder.restoreFile(in: repo.root, snapshotID: snapshot.id, path: "extra")
            #expect(!FileManager.default.fileExists(atPath: repo.root.appending(path: "extra").path))
            #expect(try repo.read("base") == "later")
            try await recorder.restoreFile(in: repo.root, snapshotID: snapshot.id, path: "new")
            #expect(try repo.read("new") == "save me")
            try repo.write("extra", "remove me")
            try await recorder.restoreTurn(in: repo.root, snapshotID: snapshot.id)
            #expect(try repo.read("base") == "snapshot")
            #expect(try await recorder.diff(in: repo.root, from: snapshot.id, to: nil).files.isEmpty)
            #expect(try await repo.git(["rev-parse", "HEAD"]) == head)
            #expect(try await repo.index() == index)
            await #expect(throws: (any Error).self) {
                try await recorder.restoreFile(in: repo.root, snapshotID: snapshot.id, path: "../escape")
            }
        }
    }

    @Test func hunkRestoreRejectsStaleReviewsAndAppliesOnlySelectedHunk() async throws {
        try await AgentControlFixture.withRepository { repo in
            try repo.write("file", repo.lines())
            try await repo.commit()
            let recorder = FlightRecorderService()
            let snapshot = try await recorder.captureSnapshot(in: repo.root)
            try repo.write("file", repo.lines([2: "early", 60: "late"]))
            try repo.write("other", "a separate diff")
            let diff = try await recorder.diff(in: repo.root, from: snapshot.id, to: nil)
            await #expect(throws: (any Error).self) {
                try await recorder.restoreHunk(
                    in: repo.root, snapshotID: snapshot.id, path: "file",
                    hunkIndex: 2, expectedDiff: diff.diffText)
            }
            try await recorder.restoreHunk(
                in: repo.root, snapshotID: snapshot.id, path: "file",
                hunkIndex: 0, expectedDiff: diff.diffText)
            #expect(try repo.read("file") == repo.lines([60: "late"]))
            await #expect(throws: (any Error).self) {
                try await recorder.restoreHunk(
                    in: repo.root, snapshotID: snapshot.id, path: "file",
                    hunkIndex: 1, expectedDiff: diff.diffText)
            }
        }
    }

    @Test func failedSafetyCaptureAbortsRestore() async throws {
        try await AgentControlFixture.withRepository { repo in
            try repo.write("file", "recorded")
            let snapshot = try await FlightRecorderService().captureSnapshot(in: repo.root)
            try repo.write("file", "preserve this edit")
            let lock = repo.root.appending(path: ".git/" + snapshot.refName + ".lock")
            try Data().write(to: lock)
            let service = FlightRecorderService()
            await #expect(throws: (any Error).self) {
                try await service.restoreTurn(in: repo.root, snapshotID: snapshot.id)
            }
            #expect(try repo.read("file") == "preserve this edit")
            #expect(try await service.listSnapshots(in: repo.root) == [snapshot])
        }
    }

    @Test func legacyRunnerCannotWriteThroughToTheRealIndex() async throws {
        try await AgentControlFixture.withRepository { repo in
            try repo.write("file", "initial")
            try await repo.commit()
            try repo.write("file", "pending")
            let before = try await repo.index()
            let recorder = FlightRecorderService(runner: ArgvOnlyRunner())
            await #expect(throws: CommandError.self) { try await recorder.captureSnapshot(in: repo.root) }
            #expect(try await repo.index() == before)
            #expect(try repo.read("file") == "pending")
        }
    }

    private struct ArgvOnlyRunner: CommandRunning {
        func run(
            executable: String, arguments: [String], directory: URL?, timeout: TimeInterval, outputLimit: Int
        )
            async throws -> CommandResult
        {
            try await CommandRunner().run(
                executable: executable, arguments: arguments, directory: directory,
                timeout: timeout, outputLimit: outputLimit)
        }
    }

    @Test func largeWorkingDiffReturnsItsBoundedPrefix() async throws {
        try await AgentControlFixture.withRepository { repo in
            let recorder = FlightRecorderService()
            let snapshot = try await recorder.captureSnapshot(in: repo.root)
            try repo.write("large", String(repeating: "some content\n", count: 180_000))
            let diff = try await recorder.diff(in: repo.root, from: snapshot.id, to: nil)
            #expect(diff.isTruncated)
            #expect(diff.diffText.utf8.count == 2 * 1_024 * 1_024)
            #expect(diff.diffText.hasPrefix("diff --git"))
            #expect(diff.files == ["large"])
        }
    }
}
