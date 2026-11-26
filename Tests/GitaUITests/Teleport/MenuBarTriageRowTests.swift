import AppKit
import GitaCore
import Testing

@testable import GitaUI

@MainActor
struct MenuBarTriageRowTests {
    private actor Attempts {
        var count = 0
        func perform() -> CommandResult {
            count += 1
            return TeleportUIRunner.result(code: count == 1 ? 1 : 0)
        }
    }

    @Test func confirmationFailureAndRetry() async throws {
        UITestSupport.bootstrap()
        let calls = Attempts()
        let facade = TeleportFacade(runner: TeleportUIRunner { _ in await calls.perform() })
        let item = TriageItem(
            id: "p", title: "Review #42", subtitle: "Ready to review", contextBadge: "App", signalState: .success,
            kind: .approvePullRequest(
                number: 42, owner: "o", repo: "r", repoPath: URL(filePath: "/tmp"), account: .active))
        let (row, presenter) = facade.makeTriageRowView(for: item)
        let host = NSViewController()
        host.view = row
        let window = UITestSupport.host(host, size: NSSize(width: 400, height: 52))
        defer { window.close() }
        presenter.triggerPrimaryAction()
        #expect(presenter.state == .confirming)
        TeleportTestSupport.render(row, width: 400, height: 52)
        #expect(TeleportTestSupport.child("teleport.triage.cancel", in: row) != nil)
        #expect(
            try row.performKeyEquivalent(
                with: TeleportTestSupport.key(KeyPress.escape, text: "\u{1b}", flags: .capsLock)))
        #expect(presenter.state == .idle && item.requiresConfirmation)
        presenter.triggerPrimaryAction()
        #expect(
            try row.performKeyEquivalent(
                with: TeleportTestSupport.key(KeyPress.returnKey, text: "\r", flags: .capsLock)))
        #expect(presenter.state == .running)
        try await TeleportTestSupport.until { if case .failed = presenter.state { true } else { false } }
        TeleportTestSupport.render(row, width: 400, height: 52)
        let retry = try #require(TeleportTestSupport.child("teleport.triage.retry", in: row) as? PartsButton)
        #expect(retry.accessibilityPerformPress())
        #expect(presenter.state == .running)
        try await TeleportTestSupport.until { if case .succeeded = presenter.state { true } else { false } }
        #expect(await calls.count == 2)
        presenter.reset()
        #expect(presenter.state == .idle)
    }

    @Test func rollbackSurvivesRowRecreation() async throws {
        UITestSupport.bootstrap()
        let repo = try TemporaryRepository()
        try repo.write(".vercel/project.json", #"{"projectId":"prj_one","orgId":"team_one","projectName":"app"}"#)
        let (release, gate) = AsyncStream<Void>.makeStream()
        defer { gate.finish() }
        let facade = TeleportFacade(
            runner: TeleportUIRunner { _ in
                for await _ in release { break }
                return TeleportUIRunner.result()
            })
        let item = TriageItem(
            id: "deploy", title: "Production", subtitle: "App", contextBadge: "", signalState: .failure,
            kind: .rollbackVercelDeployment(
                reference: "dpl_123", projectName: "app", scope: nil,
                repoPath: repo.url))
        let presenter = facade.makeTriageRowView(for: item).presenter
        presenter.triggerPrimaryAction()
        do {
            let (row, cached) = facade.makeTriageRowView(for: item)
            #expect(cached === presenter)
            let host = NSViewController()
            host.view = row
            let window = UITestSupport.host(host, size: NSSize(width: 400, height: 52))
            defer { window.close() }
            #expect(row.accessibilityValue() as? String == "Roll back production?")
            let confirm = try #require(TeleportTestSupport.child("teleport.triage.confirm", in: row) as? PartsButton)
            #expect(window.firstResponder === confirm)
            #expect(
                confirm.background == .tinted && confirm.tintFill == Theme.failure
                    && confirm.tintBorder == Theme.failure)
            #expect(confirm.parts == [.text("Roll Back", font: Theme.captionEmphasis, color: Deck.onAccent)])
            #expect(confirm.fixedHeight == 20 && confirm.cornerRadius == 5)
            #expect(confirm.accessibilityPerformPress())
        }
        let running = facade.makeTriageRowView(for: item)
        #expect(running.presenter.state == .running)
        facade.retainTriageItems([])
        #expect(facade.makeTriageRowView(for: item).presenter === presenter)
        let spinner = try #require(TeleportTestSupport.child("teleport.triage.spinner", in: running.view))
        #expect(spinner.isHidden)
        try await TeleportTestSupport.until { !spinner.isHidden }
        gate.yield()
        try await TeleportTestSupport.until { if case .succeeded = presenter.state { true } else { false } }
        let result = facade.makeTriageRowView(for: item)
        #expect(TeleportTestSupport.child("teleport.triage.result", in: result.view) != nil)
        let updated = TriageItem(
            id: "deploy", title: "Production", subtitle: "App", contextBadge: "", signalState: .failure,
            kind: .rollbackVercelDeployment(reference: "dpl_999", projectName: "app", scope: nil, repoPath: repo.url))
        let replaced = facade.makeTriageRowView(for: updated)
        #expect(replaced.presenter !== presenter && replaced.presenter.state == .idle)
        facade.retainTriageItems([])
        #expect(facade.makeTriageRowView(for: updated).presenter !== replaced.presenter)
    }

    @Test func terminalJumpUsesSelectedSession() async throws {
        UITestSupport.bootstrap()
        let target = AgentTerminalJumpTarget(
            workspaceID: "w", repoPath: URL(filePath: "/tmp"), sessionID: "42", agentName: "Agent")
        let item = TriageItem(
            id: "term", title: "Input needed", subtitle: "Active", contextBadge: "App", signalState: .pending,
            kind: .jumpToAgentTerminal(target))
        var jumped: AgentTerminalJumpTarget?
        let row = TeleportFacade().makeTriageRowView(for: item) { jumped = $0 }
        row.presenter.triggerPrimaryAction()
        try await TeleportTestSupport.until { jumped != nil }
        #expect(jumped == target && !item.requiresConfirmation)
    }
}
