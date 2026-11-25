import Foundation
import Testing

@testable import GitaCore

@Suite("HistoryPower Visual Bisect")
struct HistoryPowerBisectTests {
    @Test("Estimated steps follows logarithmic binary search bounds")
    func estimatedStepsFormula() {
        #expect(BisectStateReader.estimatedSteps(forRemaining: 0) == 0)
        #expect(BisectStateReader.estimatedSteps(forRemaining: 1) == 1)
        #expect(BisectStateReader.estimatedSteps(forRemaining: 2) == 1)
        #expect(BisectStateReader.estimatedSteps(forRemaining: 4) == 2)
        #expect(BisectStateReader.estimatedSteps(forRemaining: 8) == 3)
        #expect(BisectStateReader.estimatedSteps(forRemaining: 9) == 4)
    }

    @Test("Parses culprit SHA and custom BISECT_TERMS from metadata")
    func culpritAndCustomTermsParsing() throws {
        let sha = String(repeating: "a", count: 40)
        let goodSHA = String(repeating: "b", count: 40)
        let logLines = [
            "git bisect start",
            "# status: waiting for both good and bad commits",
            "# first bad commit: [\(sha)] Introduce regression",
        ]
        let parsed = BisectStateReader.parseCulprit(from: logLines)
        #expect(parsed?.commitID == sha)
        #expect(parsed?.subject == "Introduce regression")

        let output = "\(sha) is the first bad commit\ncommit \(sha)\n"
        #expect(BisectStateReader.parseCulpritFromOutput(output) == sha)

        let terms = BisectStateReader.parseTerms(from: Data("new\nold\n".utf8))
        #expect(terms.bad == "new")
        #expect(terms.good == "old")

        let customLog = ["# first new commit: [\(sha)] Fixed feature"]
        #expect(BisectStateReader.parseCulprit(from: customLog, badTerm: "new")?.commitID == sha)

        // Verify BisectStateReader reads BISECT_TERMS + custom refs on disk.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BisectTerms-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(
            at: tempDir.appendingPathComponent("refs/bisect"), withIntermediateDirectories: true)
        try Data("main\n".utf8).write(to: tempDir.appendingPathComponent("BISECT_START"))
        try Data("new\nold\n".utf8).write(to: tempDir.appendingPathComponent("BISECT_TERMS"))
        try Data("\(sha)\n".utf8).write(to: tempDir.appendingPathComponent("refs/bisect/new"))
        try Data("\(goodSHA)\n".utf8).write(to: tempDir.appendingPathComponent("refs/bisect/old-\(goodSHA)"))

        let snapshot = try BisectStateReader.read(gitDirectory: tempDir, head: sha)
        #expect(snapshot?.badTerm == "new")
        #expect(snapshot?.goodTerm == "old")
        #expect(snapshot?.badCommitID == sha)
        #expect(snapshot?.goodCommitIDs == [goodSHA])
    }

    @Test("Full visual bisect lifecycle identifies culprit commit and resets cleanly")
    func fullBisectLifecycle() async throws {
        let fixture = try await HistoryPowerFixture()
        defer { fixture.remove() }

        let c1 = try await fixture.commit("status.txt", "ok v1\n", message: "Commit 1 good")
        _ = try await fixture.commit("status.txt", "ok v2\n", message: "Commit 2 good")
        _ = try await fixture.commit("status.txt", "ok v3\n", message: "Commit 3 good")
        let culprit = try await fixture.commit("status.txt", "BUG\n", message: "Commit 4 introduces bug")
        _ = try await fixture.commit("status.txt", "BUG\nv2\n", message: "Commit 5 still broken")
        let c6 = try await fixture.commit("status.txt", "BUG\nv3\n", message: "Commit 6 latest broken")

        #expect(try await fixture.service.bisectState() == .inactive)

        var state = try await fixture.service.bisectStart(bad: c6, good: c1)
        guard case .active(let initialSession) = state else {
            Issue.record("Expected active bisect session")
            return
        }
        #expect(initialSession.startBranch == "main")
        #expect(initialSession.badCommitID == c6)
        #expect(initialSession.goodCommitIDs.contains(c1))
        #expect((initialSession.remainingCommits ?? 0) > 0)
        #expect((initialSession.estimatedSteps ?? 0) > 0)

        await #expect(throws: BisectError.alreadyActive) {
            _ = try await fixture.service.bisectStart(bad: c6, good: c1)
        }

        var iterations = 0
        while case .active = state, iterations < 10 {
            iterations += 1
            let content = try String(contentsOf: fixture.root.appendingPathComponent("status.txt"), encoding: .utf8)
            if content.contains("BUG") {
                state = try await fixture.service.bisectBad()
            } else {
                state = try await fixture.service.bisectGood()
            }
        }

        guard case .finished(let found) = state else {
            Issue.record("Expected bisect to identify culprit commit")
            return
        }
        #expect(found.commitID == culprit)
        #expect(found.subject == "Commit 4 introduces bug")

        let resetState = try await fixture.service.bisectReset()
        #expect(resetState == .inactive)
        #expect(try await fixture.head() == c6)
    }

    @Test("Bisect handles exit code 2 when only skipped commits remain and guards invalid transitions")
    func bisectSkipExitTwoAndGuards() async throws {
        let fixture = try await HistoryPowerFixture()
        defer { fixture.remove() }

        let c1 = try await fixture.commit("f.txt", "1\n", message: "Good base")
        _ = try await fixture.commit("f.txt", "2\n", message: "Only middle commit")
        let c3 = try await fixture.commit("f.txt", "3\n", message: "Bad tip")

        await #expect(throws: BisectError.notActive) {
            _ = try await fixture.service.bisectGood()
        }
        await #expect(throws: BisectError.notActive) {
            _ = try await fixture.service.bisectReset()
        }
        await #expect(throws: BisectError.sameCommit) {
            _ = try await fixture.service.bisectStart(bad: c3, good: c3)
        }

        _ = try await fixture.service.bisectStart(bad: c3, good: c1)

        // Skipping the single untested commit between c1 and c3 makes git bisect exit 2 with stdout diagnostic.
        do {
            _ = try await fixture.service.bisectSkip()
            Issue.record("Expected BisectError.onlySkippedRemaining when only skipped commits remain")
        } catch let error as BisectError {
            guard case .onlySkippedRemaining(let detail) = error else {
                Issue.record("Expected onlySkippedRemaining, got \(error)")
                return
            }
            #expect(!detail.isEmpty)
        }

        let afterReset = try await fixture.service.bisectReset()
        #expect(afterReset == .inactive)
    }
}
