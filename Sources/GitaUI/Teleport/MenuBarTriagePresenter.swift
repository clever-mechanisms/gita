import Foundation
import GitaCore

@MainActor
final class MenuBarTriagePresenter {
    let item: TriageItem
    var onJumpToTerminal: ((AgentTerminalJumpTarget) -> Void)?
    weak var row: MenuBarTriageRowView?
    private(set) var state: TriageActionState = .idle {
        didSet {
            row?.display(state)
            switch state {
            case .succeeded(let message), .failed(let message): TeleportControls.announce(message)
            default: break
            }
        }
    }
    private let service: MenuBarTriageService

    init(item: TriageItem, service: MenuBarTriageService = .init()) {
        self.item = item
        self.service = service
    }

    func triggerPrimaryAction() {
        guard state == .idle else { return }
        if item.requiresConfirmation { state = .confirming } else { execute() }
    }

    func confirmAction() { if state == .confirming { execute() } }
    func cancelConfirmation() { if state == .confirming { state = .idle } }
    func retry() { if case .failed = state { execute() } }

    private func execute() {
        Task { [weak self, service, item] in
            let result = await service.perform(item.kind)
            guard !Task.isCancelled, let self else { return }
            switch result {
            case .success(let message):
                self.state = .succeeded(message)
                if case .jumpToAgentTerminal(let target) = item.kind { self.onJumpToTerminal?(target) }
            case .failure(let error): self.state = .failed(error.message)
            }
        }
        state = .running
    }
}
