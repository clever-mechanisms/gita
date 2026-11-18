import Foundation
import XCTest

@testable import GitaCore

/// Provider labels and diagnostics, local source identities and the Vercel build log, with a recording runner in
/// place of `vercel`.
final class ProviderPresentationTests: XCTestCase, ProviderDetailFixtures {
    func testOrcaDiagnosticNamesTruncationOmittedHostsAndUnplacedSubagents() {
        let subagent = ProviderItem(
            id: "orca:sub", provider: .orca, category: "Orca", title: "Sub", state: .running, kind: .agent,
            agent: AgentMetadata(role: .subagent, agentName: "codex", sessionName: nil, taskTitle: nil))
        let complete = OrcaProvider.diagnostic(.init(items: [], truncated: false, remoteHostsOmitted: false))
        XCTAssertEqual(complete, String(localized: "Current local Orca sessions reported for this repository."))
        let limited = OrcaProvider.diagnostic(.init(items: [subagent], truncated: true, remoteHostsOmitted: true))
        XCTAssertTrue(
            limited.contains(
                String(localized: "Orca returned a limited workspace page; some sessions may be missing.")))
        XCTAssertTrue(limited.contains(String(localized: "Paired hosts were not queried.")))
        XCTAssertTrue(limited.contains("Delegated agents"))
    }

    func testSourceIdentityIsLocalOnly() async throws {
        let runner = DetailRecordingRunner { _ in .init(stdout: Data(), stderr: Data(), exitCode: 1) }
        let service = ProviderService(runner: runner)
        let root = try linkedFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let github = await service.sourceIdentity(
            provider: .github, root: root, github: gitHubRemote("https://github.com/Org/Repo.git"))
        XCTAssertNotNil(github)
        let none = await service.sourceIdentity(
            provider: .github, root: root, github: gitHubRemote("https://example.invalid/x"))
        XCTAssertNil(none)
        let vercel = await service.sourceIdentity(provider: .vercel, root: root, github: nil)
        XCTAssertNotNil(vercel)
        let orca = await service.sourceIdentity(provider: .orca, root: root, github: nil)
        XCTAssertNil(orca)
        let calls = await runner.calls.filter { $0.executable != "git" }
        XCTAssertTrue(calls.isEmpty, "no hosted provider is asked")
        let cancelled = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await service.sourceIdentity(provider: .vercel, root: root, github: nil)
        }.value
        XCTAssertNil(cancelled)
    }

    func testBuildLogReadsTheLastLinesOfTheLinkedDeploymentOnly() async throws {
        let root = try linkedFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let events = #"[{"type":"stdout","text":"step one\nstep two"},{"type":"deployment-state","text":"ignored"}]"#
        let runner = DetailRecordingRunner { _ in .init(stdout: Data(events.utf8), stderr: Data(), exitCode: 0) }
        let log = await ProviderService(runner: runner).vercelBuildLog(root: root, reference: "dpl_one", scope: "team")
        XCTAssertEqual(log.lines, ["step one", "step two"])
        XCTAssertEqual(log.status, .connected)
        let arguments = await runner.calls.filter { $0.executable == "vercel" }.map(\.arguments)
        XCTAssertEqual(
            arguments.first?.prefix(2), ["api", "/v3/deployments/dpl_one/events?builds=1&direction=backward&limit=40"])

        let invalid = await ProviderService(runner: runner).vercelBuildLog(root: root, reference: "--x", scope: nil)
        XCTAssertTrue(invalid.lines.isEmpty)
        XCTAssertNotEqual(invalid.status, .connected)

        let garbage = DetailRecordingRunner { _ in .init(stdout: Data("{".utf8), stderr: Data(), exitCode: 0) }
        let unverified = await ProviderService(runner: garbage).vercelBuildLog(
            root: root, reference: "dpl_one", scope: nil)
        XCTAssertEqual(unverified.diagnostic, ProviderFailure.unverified(.vercel).diagnostic)

        let failing = DetailRecordingRunner { _ in .init(stdout: Data(), stderr: Data("403".utf8), exitCode: 1) }
        let failed = await ProviderService(runner: failing).vercelBuildLog(root: root, reference: "dpl_one", scope: nil)
        XCTAssertTrue(failed.lines.isEmpty)

        let unlinked = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: unlinked, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: unlinked) }
        let notLinked = await ProviderService(runner: runner).vercelBuildLog(
            root: unlinked, reference: "dpl_one", scope: nil)
        XCTAssertEqual(notLinked.diagnostic, ProviderFailure.notLinked.diagnostic)
    }

    func testEveryReviewAgentHasANameAnExecutableAndAMarkWhereOneExists() {
        XCTAssertEqual(
            ReviewAgent.allCases.map(\.displayName),
            ["Claude", "Codex", "Cursor", "Gemini", "OpenCode", "Grok", "Copilot"])
        XCTAssertEqual(
            ReviewAgent.allCases.map(\.tool), [.claudeCode, .codex, .cursorAgent, .gemini, .opencode, nil, nil])
        XCTAssertEqual(Set(ReviewAgent.allCases.map(\.executable)).count, ReviewAgent.allCases.count)
    }
}
