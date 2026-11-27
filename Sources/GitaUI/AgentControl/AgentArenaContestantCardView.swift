import AppKit
import GitaCore

@MainActor
final class AgentArenaContestantCardView: NSView {
    private let name = Deck.label("", font: Theme.bodyEmphasis)
    private let details = Deck.hstack([])
    private let check = Deck.hstack([])
    let pick: PartsButton

    init(_ contestant: ArenaContestantID, onPick: @escaping () -> Void) {
        let title = AgentControlFormatting.contestant(contestant)
        let prefix = "arena." + contestant.rawValue
        pick = AgentControlUI.button(
            String(localized: "Pick Winner"), prefix + ".pick", symbol: "trophy.fill", action: onPick)
        pick.setAccessibilityLabel(String(localized: "Pick \(title) as winner"))
        super.init(frame: .zero)
        let card = StorageStyle.card(cornerRadius: 8)
        Style.fill(card, in: self)
        let header = Deck.hstack([
            AgentControlUI.label(title, font: Theme.caption, color: Theme.secondaryText),
            name, Deck.spacer(), pick,
        ])
        Style.fill(AgentControlUI.column([header, details, check], spacing: 4), in: card, inset: 12)
        AgentControlUI.identify(self, prefix + ".card")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("Programmatic view") }

    func update(_ config: ArenaAgentConfig, status: ArenaContestantStatus?, canPick: Bool, checks: Bool) {
        pick.isHidden = !canPick
        guard let status else { return }
        name.stringValue = config.displayName
        details.arrangedSubviews.forEach { $0.removeFromSuperview() }
        check.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let mark = Self.mark(status, checks: checks)
        details.addArrangedSubview(mark.view)
        if case .finished(let outcome) = status {
            let duration = DeckFormat.duration(outcome.durationSeconds)
            let text = String(localized: "\(duration) · \(AgentControlFormatting.files(outcome.changedFiles.count))")
            details.addArrangedSubview(AgentControlUI.label(text, font: Theme.caption, color: Theme.secondaryText))
            if let result = outcome.checkResult {
                let signal: SignalState = result.succeeded ? .success : .failure
                let label = String(localized: "Check exited \(result.exitCode)")
                let badge = AgentControlMark(
                    title: label, symbol: Style.stateSymbol(signal), color: Theme.color(for: signal))
                check.addArrangedSubview(badge.view)
                if !result.outputExcerpt.isEmpty {
                    check.addArrangedSubview(AgentControlUI.label(result.outputExcerpt, font: Theme.caption))
                }
            }
        }
        check.isHidden = check.arrangedSubviews.isEmpty
    }

    private static func mark(_ status: ArenaContestantStatus, checks: Bool) -> AgentControlMark {
        let title: String
        let signal: SignalState
        switch status {
        case .pending: (title, signal) = (String(localized: "Ready"), .pending)
        case .preparingWorktree: (title, signal) = (String(localized: "Preparing worktree"), .pending)
        case .runningAgent:
            title = checks ? String(localized: "Running agent and check") : String(localized: "Running agent")
            signal = .running
        case .runningCheck: (title, signal) = (String(localized: "Running check"), .running)
        case .cancelled: (title, signal) = (String(localized: "Cancelled"), .cancelled)
        case .failed(let message): (title, signal) = (message, .failure)
        case .finished(let result):
            title = String(localized: "Agent exited \(result.agentExitCode)")
            signal = result.agentExitCode == 0 ? .success : .failure
        }
        return AgentControlMark(title: title, symbol: Style.stateSymbol(signal), color: Theme.color(for: signal))
    }
}
