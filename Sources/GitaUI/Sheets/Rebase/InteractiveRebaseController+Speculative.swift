import AppKit
import GitaCore

/// Live speculative conflict risk badge and preview sheet for Interactive Rebase.
extension InteractiveRebaseController {
    func configureSpeculativeRisk() {
        guard let speculativeService else {
            riskBadge.isHidden = true
            return
        }
        riskBadge.isHidden = false
        let presenter = SpeculativePreviewPresenter(service: speculativeService)
        presenter.onChange = { [weak self, weak presenter] in
            guard let self, let presenter else { return }
            self.riskBadge.badgeState = Self.badgeState(for: presenter.state)
        }
        speculativePresenter = presenter
        riskBadge.onPress = { [weak self] in self?.openSpeculativePreview() }
    }

    func refreshSpeculativeRisk() {
        guard let speculativeService, let speculativePresenter else { return }
        guard review == .current, !plan.steps.isEmpty else {
            lastSimulatedKey = nil
            speculativePresenter.cancel()
            riskBadge.badgeState = .idle
            return
        }
        let steps = plan.steps
        let key = base.id + "|" + steps.map { "\($0.commitID):\($0.action.rawValue)" }.joined(separator: ",")
        guard key != lastSimulatedKey else { return }
        lastSimulatedKey = key
        let onto = base.id
        speculativePresenter.simulate(
            { .rebase(try await speculativeService.simulateRebase(onto: onto, steps: steps)) },
            debounce: .milliseconds(250))
    }

    func cancelSpeculativeRisk() {
        lastSimulatedKey = nil
        speculativePresenter?.cancel()
    }

    func openSpeculativePreview() {
        guard let speculativeService, let parent = window, review == .current, !plan.steps.isEmpty else { return }
        let panel = SpeculativeGitFacade.rebasePreview(service: speculativeService, onto: base.id, steps: plan.steps)
        SpeculativeGitFacade.presentPreview(panel, on: parent)
    }

    private static func badgeState(for state: SpeculationState<SpeculativePreviewContent>) -> ConflictBadgeState {
        switch state {
        case .idle: return .idle
        case .loading: return .checking
        case .failed(let message): return .unavailable(message)
        case .loaded(.rebase(let result)):
            switch result.overallRisk {
            case .clean: return .clean
            case .warning:
                let warnings = result.steps.filter { $0.outcome.risk == .warning }
                let detail = warnings.first?.outcome.descriptionText ?? ConflictRiskLevel.warning.title
                return .warning(count: max(1, warnings.count), detail: detail)
            case .conflict:
                return .conflict(
                    count: max(result.conflictingFiles.count, result.conflictingStepCount),
                    files: result.conflictingFiles)
            }
        case .loaded: return .clean
        }
    }
}
