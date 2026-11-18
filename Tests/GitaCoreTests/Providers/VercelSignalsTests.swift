import Foundation
import XCTest

@testable import GitaCore

/// Shapes mirror the 2026-11-10 read-only observations (key names only; values invented). Agent runs and alert groups
/// follow the documented field names: no project of ours had any.
final class VercelSignalsTests: XCTestCase {
    private let sha = String(repeating: "a", count: 40)

    func testLogCountsKeepOnlyCountsAndHonourTheCap() throws {
        let lines = """
            {"type":"request","data":{"timestamp":"2026-11-10T15:34:38.293Z","deploymentId":"dpl_live",\
            "requestPath":"/secret?token=x","httpStatus":503,"clientUserAgent":"x"}}
            {"type":"request","data":{"deploymentId":"dpl_live","httpStatus":500}}
            {"type":"summary","recordsReturned":2,"timeRange":{"start":"a","end":"b"},"pagination":{"hasMore":false,\
            "next":null},"excludedIntervals":[]}
            """
        let count = try VercelSignalParsers.count(Data(lines.utf8), kind: "request", deploymentID: "dpl_live")
        XCTAssertEqual(count.count, 2)
        XCTAssertFalse(count.capped)
        let capped = try VercelSignalParsers.count(
            Data(#"{"type":"summary","recordsReturned":100,"pagination":{"hasMore":true,"next":"eyJ"}}"#.utf8),
            kind: "log", deploymentID: "dpl_live")
        XCTAssertEqual(capped.count, 100)
        XCTAssertTrue(capped.capped)
        // No summary: an error envelope or a cut-off stream is not a count of zero.
        XCTAssertThrowsError(
            try VercelSignalParsers.count(
                Data(#"{"status":"error","reason":"invalid_arguments"}"#.utf8), kind: "log", deploymentID: "dpl_live"))
    }

    func testCIRunsMapStatesAndBecomeChecksOfTheirCommits() throws {
        let data = Data(
            """
            {"status":"ok","runs":[
              {"id":"zwKiU59VQmL7vZZvFMdIlhct","attempt":1,"status":"succeeded","repository":"org/site","branch":"preview","commitSha":"\(sha)","createdAt":"2026-11-09T14:58:53.210Z"},
              {"id":"run2","attempt":2,"status":"failed","branch":"main","commitSha":"\(sha.uppercased())","createdAt":"2026-11-09T15:58:53.210Z"},
              {"id":"run3","attempt":1,"status":"queued","branch":"main","commitSha":"not-a-sha",\
            "createdAt":"2026-11-09T16:00:00Z"},
              {"id":"run4","attempt":1,"status":"brand-new","branch":"main","commitSha":"\(sha)","createdAt":"2026-11-09T16:00:00Z"}
            ],"pagination":{"next":"eyJ"},"message":"Found 4 Vercel CI runs.","next":[]}
            """.utf8)
        let runs = try XCTUnwrap(VercelSignalParsers.ciRuns(data))
        XCTAssertEqual(runs.map(\.id), ["zwKiU59VQmL7vZZvFMdIlhct", "run2", "run4"])
        XCTAssertEqual(runs.map(\.state), [.success, .failure, .neutral])
        XCTAssertEqual(runs[1].commit, sha)
        XCTAssertTrue(try VercelSignalParsers.ciRuns(Data(#"{"status":"ok","runs":[]}"#.utf8)).isEmpty)
        let items = VercelSignals(ci: runs).ciItems()
        XCTAssertEqual(items.first?.id, "vercel-ci:run4")
        XCTAssertTrue(
            items.allSatisfy {
                $0.kind == .workflowRun && $0.provider == .vercel && $0.commit == sha && $0.target == nil
                    && $0.url == nil
            })
    }

    func testRolloutDecodesTheActiveStageAndTreatsNullAsOff() throws {
        XCTAssertNil(try VercelSignalParsers.rollout(Data(#"{"rollingRelease":null}"#.utf8)))
        let data = Data(
            """
            {"rollingRelease":{"activeStage":{"duration":null,"index":0,"isFinalStage":false,"requireApproval":false,\
            "targetPercentage":25},
              "advancementType":"manual-approval","canaryDeployment":{"createdAt":1540257589405,"id":"dpl_canary",\
            "name":"site","readyState":"READY","url":"site-abc-team.vercel.app"},
              "currentDeployment":{"id":"dpl_current","name":"site","readyState":"READY",\
            "url":"site-old-team.vercel.app","createdAt":1},
              "nextStage":{"duration":null,"index":1,"isFinalStage":true,"requireApproval":true,"targetPercentage":100},
              "queuedDeploymentId":null,"stages":[{"index":0,"targetPercentage":25,"requireApproval":false,\
            "isFinalStage":false,"duration":null},
                                                  {"index":1,"targetPercentage":100,"requireApproval":true,\
            "isFinalStage":true,"duration":null}],
              "startedAt":1716210500000,"state":"ACTIVE","substate":null,"updatedAt":1716210600000}}
            """.utf8)
        let rollout = try XCTUnwrap(VercelSignalParsers.rollout(data))
        XCTAssertTrue(rollout.isActive)
        XCTAssertEqual(rollout.canaryDeploymentID, "dpl_canary")
        XCTAssertEqual(rollout.canaryHost, "site-abc-team.vercel.app")
        XCTAssertEqual(rollout.percentage, 25)
        XCTAssertEqual(rollout.stageIndex, 0)
        XCTAssertEqual(rollout.stageCount, 2)
        XCTAssertTrue(rollout.nextStageNeedsApproval)
        XCTAssertTrue(VercelActionService.isOffered(.approve, rollout: rollout))
        var finished = rollout
        finished.state = .complete
        XCTAssertFalse(VercelActionService.isOffered(.abort, rollout: finished))
    }

    func testAgentRunsUseTheSummaryAndEmptyMeansNotInUse() throws {
        let empty = Data(
            #"""
            {"runs":[],"summary":{"runs":0,"completed":0,"failed":0,"cancelled":0,"costUsd":0},\#
            "pageInfo":{"total":0,"page":1,"pageSize":5,"hasMore":false}}
            """#
            .utf8)
        XCTAssertNil(try VercelSignalParsers.agentRuns(empty))
        let data = Data(
            #"""
            {"runs":[{"id":"run_1","status":"failed","title":"private user message",\#
            "startedAt":"2026-11-10T10:00:00Z"},{"id":"run_2","status":"completed","startedAt":1794324878293}],\#
            "summary":{"runs":7,"completed":5,"failed":2,"cancelled":0}}
            """#
            .utf8)
        let runs = try XCTUnwrap(VercelSignalParsers.agentRuns(data))
        XCTAssertEqual(runs.total, 7)
        XCTAssertEqual(runs.failed, 2)
    }

    func testAlertsAndPlatformKeepOnlyActiveFacts() throws {
        XCTAssertTrue(try VercelSignalParsers.alerts(Data(#"{"groups":[]}"#.utf8)).isEmpty)
        let alerts = try XCTUnwrap(
            VercelSignalParsers.alerts(
                Data(
                    """
                    {"groups":[{"id":"grp_1","type":"error_anomaly","title":"Error anomaly on /api",\
                    "startedAt":"2026-11-10T10:00:00Z"},
                               {"id":"grp_2","type":"usage_anomaly","status":"resolved",\
                    "startedAt":"2026-11-10T08:00:00Z"},
                               {"id":"bad id","type":"x"}]}
                    """.utf8)))
        XCTAssertEqual(alerts.map(\.id), ["grp_1", "grp_2"])
        XCTAssertEqual(VercelSignals(alerts: alerts).activeAlerts.map(\.id), ["grp_1"])

        let health = Data(
            """
            {"page":{"name":"Vercel","url":"https://www.vercel-status.com","updatedAt":"2026-11-10T14:49:36.385Z"},
             "status":{"indicator":"minor","description":"Partially Degraded Service"},
             "components":[{"id":"fk66q26xp7hh","name":"Dashboard","group":"Dashboard","status":"operational"}],
             "incidents":[{"id":"w661l7k3kf4p","name":"Build delays","status":"investigating","impact":"minor",\
            "startedAt":"2026-11-10T14:00:00Z","resolvedAt":null,
                           "url":"https://www.vercel-status.com/incidents/w661l7k3kf4p",\
            "components":[{"id":"7ckq6xr6nsbv","name":"Builds","group":"Build & Deploy"}],"updates":[]},
                          {"id":"old1","name":"Old","status":"resolved","resolvedAt":"2026-11-05T18:50:23.107Z",\
            "url":"https://evil.example/x"}],
             "scheduledMaintenances":[],"since":"2026-11-03T15:35:23.258Z"}
            """.utf8)
        let platform = try XCTUnwrap(VercelSignalParsers.platform(health))
        XCTAssertTrue(platform.isDegraded)
        XCTAssertEqual(platform.incidents.map(\.name), ["Build delays"])
        XCTAssertEqual(platform.incidents.first?.components, ["Builds"])
        let calm = try XCTUnwrap(
            VercelSignalParsers.platform(
                Data(#"{"status":{"indicator":"none","description":"All Systems Operational"},"incidents":[]}"#.utf8)))
        XCTAssertFalse(calm.isDegraded)
    }

    func testGateReadsEachPartOnItsOwnLifetime() {
        let now = Date()
        var signals = VercelSignals(reads: [
            .errors: .init(at: now.addingTimeInterval(-60), key: "dpl_live", outcome: .value),
            .ci: .init(at: now.addingTimeInterval(-3600), key: "list", outcome: .empty),
            .agentRuns: .init(at: now.addingTimeInterval(-700), key: "", outcome: .value),
        ])
        XCTAssertFalse(signals.isDue(.errors, key: "dpl_live", now: now))
        XCTAssertTrue(signals.isDue(.errors, key: "dpl_new", now: now), "a new live deployment is read at once")
        XCTAssertFalse(signals.isDue(.ci, key: "list", now: now), "an unused feature waits six hours")
        XCTAssertTrue(signals.isDue(.ci, key: "list2", now: now), "a new deployment list re-checks CI")
        XCTAssertTrue(signals.isDue(.agentRuns, key: "", now: now))
        XCTAssertTrue(signals.isDue(.alerts, key: "", now: now), "never read")
        XCTAssertTrue(signals.isDue(.errors, key: "dpl_live", now: now, force: true))
        signals.reads[.ci] = .init(at: now.addingTimeInterval(-90), key: "list", outcome: .value)
        signals.ci = [
            .init(id: "r", status: .running, branch: "main", commit: sha, createdAt: now)
        ]
        XCTAssertTrue(signals.isDue(.ci, key: "list", now: now), "a running CI run is re-read every minute")
    }
}
