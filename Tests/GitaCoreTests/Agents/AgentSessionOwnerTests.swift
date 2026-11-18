import Foundation
import Testing

@testable import GitaCore

/// Who owns a session's state: CPU inference, Orca's reports while they keep coming, or hooks for good. The
/// evidence a session shows follows its owner.
@Suite struct AgentSessionOwnerTests {
    private let all = Set(AgentTool.allCases)
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let repo = URL(fileURLWithPath: "/Users/u/projects/app", isDirectory: true)
    private var checkout: AgentCheckout {
        AgentCheckout(
            checkoutRoot: repo, repositoryRoot: repo, gitDirectory: repo.appendingPathComponent(".git"), branch: "main")
    }

    private func sample(cpu: Double) -> AgentProcessSample {
        AgentProcessSample(
            tool: .claudeCode, pid: 100, parentAgentPID: nil, workingDirectory: repo.path, startedAt: start,
            cpuSeconds: cpu, isService: false)
    }

    private func feed(_ book: inout AgentSessionBook, cpu: Double, at time: TimeInterval) {
        book.apply([sample(cpu: cpu)], checkouts: [repo.path: checkout], enabled: all, time: time, now: start)
    }

    private func report(_ state: AgentState) -> AgentStateReport {
        AgentStateReport(tool: .claudeCode, checkout: repo.path, state: state)
    }

    @Test func aSessionWithoutReportsOrHooksIsInferred() {
        var book = AgentSessionBook()
        feed(&book, cpu: 0, at: 0)
        #expect(book.entries.values.first?.owner == .process)
        #expect(book.sessions().first?.evidence == .process)
    }

    @Test func staleReportsHandTheSessionBackToCPU() {
        var book = AgentSessionBook()
        feed(&book, cpu: 0, at: 0)
        book.applyReported([report(.needsInput)], time: 1, now: start)
        #expect(book.entries.values.first?.owner == .reported(time: 1))
        feed(&book, cpu: 0, at: 2)
        #expect(book.sessions().first?.evidence == .orca)
        // No report for longer than its lifetime: CPU owns the state again, and Orca is no longer the evidence.
        let late = 1 + AgentSessionBook.reportLifetime
        feed(&book, cpu: 0, at: late)
        #expect(book.entries.values.first?.owner == .process)
        #expect(book.sessions().first?.evidence == .process)
        // A busy CPU now decides the state.
        feed(&book, cpu: 20, at: late + 2)
        #expect(book.sessions().first?.state == .working)
        // A new report takes the state back.
        book.applyReported([report(.needsInput)], time: late + 3, now: start)
        #expect(book.sessions().first?.state == .needsInput)
        #expect(book.sessions().first?.evidence == .orca)
    }

    @Test func aHookTakesOverFromReportsForGood() {
        var book = AgentSessionBook()
        feed(&book, cpu: 0, at: 0)
        book.applyReported([report(.working)], time: 1, now: start)
        let event = AgentHookEvent(tool: .claudeCode, event: "Stop", sessionID: "s1", pids: [100])
        #expect(book.handle(event, enabled: all, allowHookOnly: false, time: 2, now: start) == .applied)
        #expect(book.entries.values.first?.owner == .hooked(.init(time: 2, date: start, sessionID: "s1")))
        #expect(book.applyReported([report(.working)], time: 3, now: start) == false)
        #expect(book.sessions().first?.state == .done)
        #expect(book.sessions().first?.evidence == .hook)
        // Long after any report would have expired, hooks still own the session.
        feed(&book, cpu: 0, at: 2 + AgentSessionBook.reportLifetime * 2)
        #expect(book.sessions().first?.evidence == .hook)
    }

    @Test func aHookWithoutASessionIDKeepsTheOneSeenBefore() {
        var book = AgentSessionBook()
        feed(&book, cpu: 0, at: 0)
        _ = book.handle(
            AgentHookEvent(tool: .claudeCode, event: "UserPromptSubmit", sessionID: "s1", pids: [100]),
            enabled: all, allowHookOnly: false, time: 1, now: start)
        _ = book.handle(
            AgentHookEvent(tool: .claudeCode, event: "Notification", pids: [100]), enabled: all,
            allowHookOnly: false, time: 2, now: start)
        #expect(book.entries.values.first?.owner.hook?.sessionID == "s1")
        // A later hook naming only the session still finds it.
        let bySession = AgentHookEvent(tool: .claudeCode, event: "Stop", sessionID: "s1")
        #expect(book.match(bySession) == book.entries.values.first?.id)
    }

    @Test func hookOnlySessionsExpireByTheirLastHook() {
        var book = AgentSessionBook()
        let event = AgentHookEvent(
            tool: .codex, event: "notify", sessionID: "c1", cwd: "/Users/u/elsewhere", kind: "agent-turn-complete")
        #expect(
            book.handle(event, enabled: all, allowHookOnly: true, time: 0, now: start)
                == .created(id: "\(AgentTool.codex.rawValue)-c1", directory: "/Users/u/elsewhere"))
        let soon = start.addingTimeInterval(AgentSessionBook.hookOnlyLifetime - 1)
        book.apply([], checkouts: [:], enabled: all, time: 1, now: soon)
        #expect(book.sessions().count == 1)
        let late = start.addingTimeInterval(AgentSessionBook.hookOnlyLifetime + 1)
        book.apply([], checkouts: [:], enabled: all, time: 2, now: late)
        #expect(book.sessions().isEmpty)
    }
}

/// The CPU tracker's phases: undecided until a first rate, then idle or working with when the turn began.
@Suite struct AgentActivityPhaseTests {
    @Test func phasesFollowTheRate() {
        var tracker = AgentActivityTracker()
        #expect(tracker.phase == .undecided)
        #expect(tracker.add(time: 0, cpu: 0) == nil)
        #expect(tracker.phase == .undecided && !tracker.hasDecided)
        #expect(tracker.add(time: 2, cpu: 0) == nil)
        #expect(tracker.phase == .idle && tracker.hasDecided)
        #expect(tracker.add(time: 8, cpu: 1) == .started)
        #expect(tracker.phase == .working(since: 8, lastActive: 8))
        #expect(tracker.isWorking && tracker.workingSince == 8)
        // Sustained work moves the last active sample, not the start.
        #expect(tracker.add(time: 20, cpu: 9) == nil)
        #expect(tracker.phase == .working(since: 8, lastActive: 20))
        // Quiet, but not yet for the quiet period: still working.
        #expect(tracker.add(time: 30, cpu: 9) == nil)
        #expect(tracker.isWorking)
        // Twelve seconds of work: a finished turn, and idle again.
        #expect(tracker.add(time: 41, cpu: 9) == .finished)
        #expect(tracker.phase == .idle && tracker.workingSince == nil)
    }
}
