import Foundation
import GitaCore

@MainActor
final class FlightCheckPresenter: NSObject {
    static let didChange = Notification.Name("Gita.ControlPlane.FlightCheckChanged")
    let root: URL
    private let git: GitService
    private let service: PrePushFlightCheckService
    private let store: FlightCheckSettingsStore
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private(set) var command: FlightCheckCommand?
    private(set) var cached = false
    private(set) var state: FlightCheckState {
        didSet { NotificationCenter.default.post(name: Self.didChange, object: self) }
    }

    init(root: URL, git: GitService, service: PrePushFlightCheckService, store: FlightCheckSettingsStore) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.git = git
        self.service = service
        self.store = store
        command = store.command(for: root)
        state = command == nil ? .unconfigured : .idle(lastResult: nil)
    }
    deinit { task?.cancel() }

    @discardableResult func configure(_ candidate: FlightCheckCommand) -> Bool {
        guard !busy else { return false }
        do {
            try store.save(candidate, for: root)
            if candidate != command {
                command = candidate
                cached = false
                state = .idle(lastResult: nil)
            }
            return true
        } catch {
            cached = false
            state = .error(message: error.localizedDescription)
            return false
        }
    }

    var busy: Bool {
        switch state {
        case .preparing, .running: true
        default: false
        }
    }

    @discardableResult func run(force: Bool = false) -> Task<Void, Never>? {
        guard let command else {
            state = .unconfigured
            return nil
        }
        task?.cancel()
        let id = UUID()
        generation = id
        cached = false
        state = .preparing(commitSHA: "")
        let work = Task { [weak self, git, service] in
            let result = await service.run(gitService: git, command: command, force: force) { [weak self] state in
                await self?.receive(state, id: id)
            }
            guard self?.generation == id else { return }
            self?.cached = result.cached
            self?.state = result.state
        }
        task = work
        return work
    }

    private func receive(_ state: FlightCheckState, id: UUID) {
        guard id == generation else { return }
        self.state = state
    }

    func cancel() { task?.cancel() }
}
