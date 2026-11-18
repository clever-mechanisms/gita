import Foundation
import Testing

@testable import GitaCore

/// A rolling release's state is one of Vercel's three words, and a step is offered only on an active rollout that
/// the last read returned.
@Suite struct VercelRolloutStateTests {
    private static func release(state: String, substate: String = "null") -> Data {
        Data(
            """
            {"rollingRelease":{"activeStage":{"index":0,"targetPercentage":25,"requireApproval":false},
              "advancementType":"manual-approval",
              "canaryDeployment":{"id":"dpl_canary","url":"site-abc-team.vercel.app"},
              "nextStage":{"index":1,"targetPercentage":100,"requireApproval":true},
              "stages":[{"index":0},{"index":1}],"state":"\(state)","substate":\(substate)}}
            """.utf8)
    }

    private static let words: [(String, VercelSignals.Rollout.State)] = [
        ("ACTIVE", .active), ("active", .active), ("COMPLETE", .complete), ("aborted", .aborted),
    ]

    private static func rollout(_ state: String, paused: Bool = false) throws -> VercelSignals.Rollout {
        try #require(try VercelSignalParsers.rollout(release(state: state, substate: paused ? "\"PAUSED\"" : "null")))
    }

    @Test(arguments: words)
    func vercelsWordsAreTheStates(_ word: String, _ state: VercelSignals.Rollout.State) throws {
        #expect(try VercelSignalParsers.rollout(Self.release(state: word))?.state == state)
    }

    @Test func anyOtherWordIsAnUnreadableResponse() {
        #expect(throws: ProviderResponseError.self) { try VercelSignalParsers.rollout(Self.release(state: "DONE")) }
    }

    @Test func pausedIsASubstateOfAnActiveRolloutOnly() throws {
        #expect(try Self.rollout("ACTIVE", paused: true).isPaused)
        #expect(try !Self.rollout("ABORTED", paused: true).isPaused)
    }

    /// A manual-approval release pauses at the stage that waits for approval: approving is what resumes it.
    @Test func aPausedRolloutStillOffersApproval() throws {
        let paused = try Self.rollout("ACTIVE", paused: true)
        #expect(
            VercelActionService.RolloutAction.allCases.allSatisfy { VercelActionService.isOffered($0, rollout: paused) }
        )
    }

    @Test func endedOrStaleRolloutsOfferNothing() throws {
        let active = try Self.rollout("ACTIVE")
        #expect(VercelActionService.isOffered(.approve, rollout: active))
        var stale = active
        stale.freshness = .stale
        var complete = active
        complete.state = .complete
        for rollout in [stale, complete] {
            #expect(
                !VercelActionService.RolloutAction.allCases.contains {
                    VercelActionService.isOffered($0, rollout: rollout)
                })
        }
    }

    /// A failed read keeps the rollout to show, marked stale; the next good read makes it current again.
    @Test func aFailedReadLeavesTheKeptRolloutStale() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GitaVercelRollout-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".vercel"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"orgId":"team_one","projectId":"prj_one"}"#.utf8).write(
            to: root.appendingPathComponent(".vercel/project.json"))
        let link = VercelLink(root: root, sourceID: VercelLink.sourceID(org: "team_one", project: "prj_one"))
        let runner = RolloutRunner()
        let reader = VercelSignalReader(
            executor: ProviderCommandExecutor(runner: runner), cache: VercelPlatformCache(), clock: { Date() })

        await runner.answer(Self.release(state: "ACTIVE"))
        let first = await reader.read(link: link, live: nil, fingerprint: "f", previous: nil, force: true)
        #expect(first.rollout?.freshness == .current)
        #expect(first.reads[.rollout]?.outcome == .value)

        await runner.answer(nil)
        let failed = await reader.read(link: link, live: nil, fingerprint: "f", previous: first, force: true)
        #expect(failed.reads[.rollout]?.outcome == .failed)
        #expect(failed.rollout?.stageIndex == 0, "the kept rollout is still shown")
        #expect(failed.rollout?.freshness == .stale)
        #expect(!VercelActionService.isOffered(.approve, rollout: failed.rollout))

        await runner.answer(Self.release(state: "ACTIVE"))
        let again = await reader.read(link: link, live: nil, fingerprint: "f", previous: failed, force: true)
        #expect(again.rollout?.freshness == .current)
    }
}

/// Answers the rolling-release read with `rollout` (nil: the command fails) and fails every other read.
private actor RolloutRunner: CommandRunning {
    private var rollout: Data?

    func answer(_ data: Data?) { rollout = data }

    func run(
        executable _: String, arguments: [String], directory _: URL?, timeout _: TimeInterval, outputLimit _: Int
    ) async throws -> CommandResult {
        if let rollout, arguments.contains(where: { $0.contains("rolling-release") }) {
            return CommandResult(stdout: rollout, stderr: Data(), exitCode: 0)
        }
        return CommandResult(stdout: Data(), stderr: Data("offline".utf8), exitCode: 1)
    }
}
