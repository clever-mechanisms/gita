import AppKit
import GitaCore

@MainActor
final class AgentControlFacade {
    private let collisionRadar: CollisionRadarService
    private let flightRecorder: FlightRecorderService
    private let arena: AgentArenaService
    private let resolver = AgentCheckoutResolver()
    private let radars = NSHashTable<CollisionRadarViewController>.weakObjects()
    private let recorders = NSHashTable<AgentFlightRecorderViewController>.weakObjects()
    private let arenas = NSHashTable<AgentArenaViewController>.weakObjects()
    private var queues: [URL: AgentControlQueue] = [:]
    var onHookError: ((URL, String) -> Void)?

    init(
        collisionRadar: CollisionRadarService = CollisionRadarService(),
        flightRecorder: FlightRecorderService = FlightRecorderService(),
        arena: AgentArenaService = AgentArenaService()
    ) {
        self.collisionRadar = collisionRadar
        self.flightRecorder = flightRecorder
        self.arena = arena
    }

    func makeCollisionRadarViewController(for repositoryRoot: URL) -> CollisionRadarViewController {
        let presenter = CollisionRadarPresenter(service: collisionRadar, repositoryRoot: canonical(repositoryRoot))
        let controller = CollisionRadarViewController(presenter: presenter)
        radars.add(controller)
        return controller
    }

    func makeFlightRecorderViewController(for repositoryRoot: URL) -> AgentFlightRecorderViewController {
        let presenter = FlightRecorderPresenter(service: flightRecorder, repositoryRoot: canonical(repositoryRoot))
        let controller = AgentFlightRecorderViewController(presenter: presenter)
        recorders.add(controller)
        return controller
    }

    func makeArenaViewController(for repositoryRoot: URL, baseCommit: String = "HEAD") -> AgentArenaViewController {
        let presenter = AgentArenaPresenter(service: arena, repositoryRoot: canonical(repositoryRoot))
        let controller = AgentArenaViewController(presenter)
        controller.setup.setBase(baseCommit)
        arenas.add(controller)
        return controller
    }

    @discardableResult
    func handleHookEvent(_ event: AgentHookEvent, repositoryRoot: URL) -> Task<Void, Never> {
        let root = canonical(repositoryRoot)
        let history = FlightHistory(service: flightRecorder, root: root)
        return queue(for: root).append { [weak self, flightRecorder, resolver] in
            do {
                guard let snapshot = try await flightRecorder.handleHookEvent(event, repositoryRoot: root) else {
                    return
                }
                let key: String
                if let session = snapshot.sessionID {
                    key = session
                } else if let cwd = event.cwd,
                    let checkout = await resolver.resolve(cwd, allowedRoots: [root.path, cwd])
                {
                    key = checkout.checkoutRoot.resolvingSymlinksInPath().path
                } else {
                    key = root.path
                }
                history.remember(key)
                if !Task.isCancelled { self?.refreshRecorders(for: root) }
            } catch  where !Task.isCancelled {
                self?.onHookError?(root, error.localizedDescription)
            } catch {}
        }
    }

    private func refreshRecorders(for root: URL) {
        for controller in recorders.allObjects
        where controller.presenter.history.root == root
            && controller.isViewLoaded && controller.view.window?.isVisible == true
        {
            controller.presenter.load()
        }
    }

    private func canonical(_ root: URL) -> URL { root.standardizedFileURL.resolvingSymlinksInPath() }

    private func queue(for root: URL) -> AgentControlQueue {
        if let queue = queues[root] { return queue }
        let queue = AgentControlQueue()
        queues[root] = queue
        return queue
    }

    var hasActiveRace: Bool {
        arenas.allObjects.contains { controller in
            switch controller.presenter.state {
            case .racing, .cancelling: true
            default: false
            }
        }
    }

    func cancelAll() {
        radars.allObjects.forEach { $0.presenter.cancel() }
        recorders.allObjects.forEach { $0.presenter.cancel() }
        arenas.allObjects.forEach { $0.presenter.cancelAndCleanup() }
        queues.values.forEach { $0.cancelReads() }
    }
}
