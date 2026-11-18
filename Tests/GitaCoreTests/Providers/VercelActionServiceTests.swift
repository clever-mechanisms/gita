import Foundation
import XCTest

@testable import GitaCore

/// Deployment and rolling-release actions: which ones are offered for which deployment, the exact `vercel` command
/// each runs in the linked checkout, and what a failed or unlinked call reports. `vercel` is never really run.
final class VercelActionServiceTests: XCTestCase, ProviderDetailFixtures {
    private let liveHost = URL(string: "https://demo-live-team.vercel.app")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(
        _ state: SignalState, host: String = "demo-one-team.vercel.app", reference: String = "dpl_one",
        environment: DeploymentSummary.Environment = .preview, date: Date? = nil, scope: String? = "team"
    ) -> ProviderItem {
        ProviderItem(
            id: "vercel:\(reference)", provider: .vercel, category: "Vercel", title: "demo", state: state,
            url: URL(string: "https://\(host)"), date: date, kind: .deployment,
            target: .deployment(reference: reference, projectName: "demo", scope: scope),
            deployment: DeploymentSummary(environment: environment))
    }

    private var context: VercelContext {
        VercelContext(production: .init(deploymentID: "dpl_live", url: liveHost, createdAt: now))
    }

    func testOfferedActionsFollowTheDeploymentState() {
        typealias Service = VercelActionService
        let ready = item(.success)
        XCTAssertTrue(Service.isOffered(.promote, for: ready, context: context))
        XCTAssertFalse(Service.isOffered(.promote, for: ready, context: nil), "promote needs a known production")
        XCTAssertFalse(Service.isOffered(.rollback, for: ready, context: context))
        let older = item(.success, environment: .production, date: now.addingTimeInterval(-60))
        XCTAssertTrue(Service.isOffered(.rollback, for: older, context: context))
        XCTAssertFalse(Service.isOffered(.promote, for: older, context: context))
        let live = item(.success, host: "demo-live-team.vercel.app", environment: .production, date: now)
        XCTAssertFalse(Service.isOffered(.promote, for: live, context: context))
        XCTAssertFalse(Service.isOffered(.rollback, for: live, context: context))
        XCTAssertTrue(Service.isOffered(.redeploy, for: item(.failure), context: context))
        XCTAssertTrue(Service.isOffered(.redeploy, for: item(.cancelled), context: context))
        XCTAssertFalse(Service.isOffered(.redeploy, for: ready, context: context))
        XCTAssertTrue(Service.isOffered(.cancel, for: item(.running), context: context))
        XCTAssertTrue(Service.isOffered(.cancel, for: item(.pending), context: context))
        XCTAssertFalse(Service.isOffered(.cancel, for: ready, context: context))
        var notDeployment = ready
        notDeployment.kind = .other
        XCTAssertTrue(
            Service.Action.allCases.allSatisfy { !Service.isOffered($0, for: notDeployment, context: context) })
    }

    func testEachActionRunsItsCommandInTheLinkedCheckout() async throws {
        let root = try linkedFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = DetailRecordingRunner { _ in .init(stdout: Data("{}".utf8), stderr: Data(), exitCode: 0) }
        let service = VercelActionService(runner: runner)
        for action in [VercelActionService.Action.promote, .rollback, .redeploy, .cancel] {
            let result = await service.perform(action, item: item(.success), root: root)
            XCTAssertEqual(result, .init(succeeded: true, message: VercelActionService.requested(action)))
        }
        let vercel = await runner.calls.filter { $0.executable == "vercel" }
        XCTAssertEqual(
            vercel.map(\.arguments),
            [
                ["promote", "dpl_one", "--timeout", "0", "--yes", "--non-interactive", "--scope", "team"],
                ["rollback", "dpl_one", "--timeout", "0", "--yes", "--non-interactive", "--scope", "team"],
                ["redeploy", "dpl_one", "--no-wait", "--non-interactive", "--scope", "team"],
                [
                    "api", "/v12/deployments/dpl_one/cancel", "--method", "PATCH", "--raw", "--non-interactive",
                    "--scope", "team",
                ],
            ])
        XCTAssertTrue(vercel.allSatisfy { $0.directory?.standardizedFileURL == root.standardizedFileURL })
        XCTAssertTrue(vercel.allSatisfy { $0.timeout == 90 && $0.outputLimit == 512 * 1_024 })
    }

    func testCancellingByHostLooksUpTheSameDeploymentFirst() async throws {
        let root = try linkedFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = "demo-one-team.vercel.app"
        let runner = DetailRecordingRunner { call in
            if call.arguments.contains("GET") {
                return .init(stdout: Data(#"{"id":"dpl_one","url":"\#(host)"}"#.utf8), stderr: Data(), exitCode: 0)
            }
            return .init(stdout: Data(), stderr: Data(), exitCode: 0)
        }
        let result = await VercelActionService(runner: runner).perform(
            .cancel, item: item(.running, reference: host, scope: nil), root: root)
        XCTAssertTrue(result.succeeded)
        let arguments = await runner.calls.filter { $0.executable == "vercel" }.map(\.arguments)
        XCTAssertEqual(
            arguments.last,
            ["api", "/v12/deployments/dpl_one/cancel", "--method", "PATCH", "--raw", "--non-interactive"])

        let other = DetailRecordingRunner { call in
            if call.arguments.contains("GET") {
                return .init(
                    stdout: Data(#"{"id":"dpl_two","url":"other.vercel.app"}"#.utf8), stderr: Data(), exitCode: 0)
            }
            return .init(stdout: Data(), stderr: Data(), exitCode: 0)
        }
        let refused = await VercelActionService(runner: other).perform(
            .cancel, item: item(.running, reference: host, scope: nil), root: root)
        XCTAssertFalse(refused.succeeded)
        let patched = await other.calls.contains { $0.arguments.contains("PATCH") }
        XCTAssertFalse(patched, "a different deployment is never cancelled")
    }

    func testInvalidIdentityUnlinkedCheckoutAndFailedCommandsAreReported() async throws {
        let runner = DetailRecordingRunner { _ in .init(stdout: Data(), stderr: Data("boom".utf8), exitCode: 1) }
        let service = VercelActionService(runner: runner)
        let unsafe = await service.perform(
            .promote, item: item(.success, reference: "--help"), root: URL(fileURLWithPath: "/tmp"))
        XCTAssertFalse(unsafe.succeeded)
        let badScope = await service.perform(
            .promote, item: item(.success, scope: "--token"), root: URL(fileURLWithPath: "/tmp"))
        XCTAssertFalse(badScope.succeeded)
        let noCalls = await runner.calls.filter { $0.executable == "vercel" }
        XCTAssertTrue(noCalls.isEmpty)

        let unlinked = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: unlinked, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: unlinked) }
        let notLinked = await service.perform(.redeploy, item: item(.failure), root: unlinked)
        XCTAssertEqual(notLinked.message, ProviderFailure.notLinked.diagnostic)

        let root = try linkedFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let failed = await service.perform(.redeploy, item: item(.failure), root: root)
        XCTAssertFalse(failed.succeeded)
        XCTAssertFalse(failed.message.isEmpty)

        let throwing = DetailRecordingRunner { call in
            if call.executable == "vercel" { throw CommandError.timedOut }
            return .init(stdout: Data(), stderr: Data(), exitCode: 0)
        }
        let incomplete = await VercelActionService(runner: throwing).perform(
            .redeploy, item: item(.failure), root: root)
        XCTAssertEqual(incomplete.message, ProviderFailure.incomplete(.vercel).diagnostic)
    }

    func testRollingReleaseStepsNeedAnActiveRolloutAndTheCanaryID() async throws {
        let active = VercelSignals.Rollout(
            state: .active, canaryDeploymentID: "dpl_canary", stageIndex: 1, stageCount: 3,
            nextStageNeedsApproval: true)
        let waiting = VercelSignals.Rollout(state: .active, canaryDeploymentID: "dpl_canary", stageIndex: 1)
        XCTAssertTrue(VercelActionService.isOffered(.approve, rollout: active))
        XCTAssertFalse(VercelActionService.isOffered(.approve, rollout: waiting))
        XCTAssertTrue(VercelActionService.isOffered(.complete, rollout: waiting))
        XCTAssertTrue(VercelActionService.isOffered(.abort, rollout: waiting))
        XCTAssertFalse(VercelActionService.isOffered(.abort, rollout: VercelSignals.Rollout(state: .complete)))
        XCTAssertFalse(VercelActionService.isOffered(.abort, rollout: nil))

        let root = try linkedFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = DetailRecordingRunner { _ in .init(stdout: Data(), stderr: Data(), exitCode: 0) }
        let service = VercelActionService(runner: runner)
        for action in VercelActionService.RolloutAction.allCases {
            let result = await service.perform(action, rollout: active, root: root, scope: "team")
            XCTAssertEqual(result, .init(succeeded: true, message: VercelActionService.completed(action)))
        }
        let refused = await service.perform(.approve, rollout: waiting, root: root, scope: "team")
        XCTAssertFalse(refused.succeeded)
        let arguments = await runner.calls.filter { $0.executable == "vercel" }.map(\.arguments)
        XCTAssertEqual(
            arguments,
            [
                [
                    "rolling-release", "approve", "--currentStageIndex=1", "--deployment=dpl_canary",
                    "--non-interactive", "--scope", "team",
                ],
                ["rolling-release", "complete", "--deployment=dpl_canary", "--non-interactive", "--scope", "team"],
                ["rolling-release", "abort", "--deployment=dpl_canary", "--non-interactive", "--scope", "team"],
            ])
    }
}
