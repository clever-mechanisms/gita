import Foundation
import GitaCore

enum ArenaDiffMode: Int, CaseIterable { case alphaVsBeta, alphaVsBase, betaVsBase }

@MainActor
final class AgentArenaPresenter {
    let presets = ArenaAgentConfig.defaultPresets
    var alphaConfig: ArenaAgentConfig
    var betaConfig: ArenaAgentConfig
    var baseCommit = "HEAD"
    var prompt = ""
    var checkArguments: [String] = []
    var diffMode = ArenaDiffMode.alphaVsBeta { didSet { onStateChange?() } }
    private(set) var state = AgentArenaState.idle { didSet { onStateChange?() } }
    private(set) var task: Task<Void, Never>?
    private(set) var workspaces: [ArenaWorkspace] = []
    private(set) var decisionError: String?
    private let service: AgentArenaService
    let root: URL
    var onStateChange: (() -> Void)?

    init(service: AgentArenaService, repositoryRoot: URL) {
        self.service = service
        root = repositoryRoot
        alphaConfig = ArenaAgentConfig.defaultPresets[0]
        betaConfig = ArenaAgentConfig.defaultPresets[1]
    }

    var canStart: Bool {
        switch state {
        case .idle, .failed: workspaces.isEmpty
        default: false
        }
    }

    func startRace(checkCommand: String? = nil) {
        guard canStart else { return }
        if let checkCommand {
            do { checkArguments = try ArenaCommandArguments.parse(checkCommand) } catch {
                state = .failed(error.localizedDescription)
                return
            }
        }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            state = .failed(String(localized: "Enter a prompt for both contestants."))
            return
        }
        let race = ArenaRace(
            service: service, root: root, base: baseCommit, prompt: prompt,
            alpha: alphaConfig, beta: betaConfig, check: checkArguments)
        task = Task {
            do {
                _ = try await service.createWorktrees(in: root, baseCommit: race.base, runID: race.id) { planned in
                    await MainActor.run { self.workspaces = planned }
                }
                try Task.checkCancellation()
                let comparison = try await race.compare(workspaces) { status in
                    if self.state != .cancelling { self.state = status }
                }
                try Task.checkCancellation()
                state = .comparing(comparison)
            } catch {
                if Task.isCancelled {
                    state = .cancelling
                    await service.cleanup(in: root, workspaces: workspaces)
                    workspaces = []
                    state = .idle
                } else {
                    state = .failed(error.localizedDescription)
                }
            }
            task = nil
        }
        state = race.state(alpha: .preparingWorktree, beta: .preparingWorktree)
    }

    func pickWinner(_ contestant: ArenaContestantID) {
        guard case .comparing(let comparison) = state else { return }
        decisionError = nil
        state = .pickingWinner(contestant)
        task = Task {
            do {
                let kept = try await service.pickWinner(contestant, in: root, comparison: comparison)
                workspaces = []
                state = .completed(winner: contestant, keptWorktree: kept.keptWorktree, keptBranch: kept.keptBranch)
            } catch {
                decisionError = error.localizedDescription
                state = .comparing(comparison)
            }
            task = nil
        }
    }

    func cancelAndCleanup() {
        switch state {
        case .racing:
            state = .cancelling
            task?.cancel()
        case .comparing:
            cleanupWorkspaces()
        case .failed where !workspaces.isEmpty:
            cleanupWorkspaces()
        case .completed: state = .idle
        default: break
        }
    }

    private func cleanupWorkspaces() {
        state = .cancelling
        decisionError = nil
        task = Task {
            await service.cleanup(in: root, workspaces: workspaces)
            workspaces = []
            task = nil
            state = .idle
        }
    }

    var comparisonText: String {
        guard case .comparing(let comparison) = state else { return "" }
        switch diffMode {
        case .alphaVsBeta: return comparison.alphaVsBetaDiff
        case .alphaVsBase: return comparison.alpha.diffFromBase
        case .betaVsBase: return comparison.beta.diffFromBase
        }
    }
}

private struct ArenaRace: Sendable {
    let service: AgentArenaService
    let root: URL
    let base: String
    let prompt: String
    let alpha: ArenaAgentConfig
    let beta: ArenaAgentConfig
    let check: [String]
    let id = UUID().uuidString

    func state(alpha: ArenaContestantStatus, beta: ArenaContestantStatus) -> AgentArenaState {
        .racing(runID: id, prompt: prompt, baseCommit: base, alpha: alpha, beta: beta)
    }

    func compare(
        _ workspaces: [ArenaWorkspace], update: @MainActor (AgentArenaState) -> Void
    ) async throws
        -> ArenaComparison
    {
        var statuses: [ArenaContestantID: ArenaContestantStatus] = [:]
        await update(state(alpha: .runningAgent, beta: .runningAgent))
        await withTaskGroup(of: (ArenaContestantID, ArenaContestantStatus).self) { group in
            for workspace in workspaces {
                group.addTask { (workspace.id, await status(for: workspace)) }
            }
            for await (contestant, result) in group {
                statuses[contestant] = result
                await update(state(alpha: statuses[.alpha] ?? .runningAgent, beta: statuses[.beta] ?? .runningAgent))
            }
        }
        try Task.checkCancellation()
        let a = try outcome(statuses[.alpha])
        let b = try outcome(statuses[.beta])
        return try await service.compare(in: root, runID: id, prompt: prompt, baseCommit: base, alpha: a, beta: b)
    }

    private func status(for workspace: ArenaWorkspace) async -> ArenaContestantStatus {
        do {
            let outcome = try await service.runContestant(
                workspace, config: workspace.id == .alpha ? alpha : beta,
                prompt: prompt, baseCommit: "HEAD",
                checkCommand: check.isEmpty ? nil : check)
            return .finished(outcome)
        } catch { return Task.isCancelled ? .cancelled : .failed(error.localizedDescription) }
    }

    private func outcome(_ status: ArenaContestantStatus?) throws -> ArenaContestantOutcome {
        if case .finished(let result) = status { return result }
        if case .failed(let reason) = status { throw RaceFailure(errorDescription: reason) }
        throw CancellationError()
    }

    private struct RaceFailure: LocalizedError { let errorDescription: String? }
}
