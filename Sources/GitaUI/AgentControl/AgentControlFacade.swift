import AppKit
import GitaCore

@MainActor
public final class AgentControlFacade {
    private let collisionRadar: CollisionRadarService
    private let flightRecorder: FlightRecorderService
    private let arena: AgentArenaService
    private let resolver = AgentCheckoutResolver()
    private let radars = NSHashTable<CollisionRadarViewController>.weakObjects()
    private let recorders = NSHashTable<AgentFlightRecorderViewController>.weakObjects()
    private let reviews = NSHashTable<ReviewedHunksPresenter>.weakObjects()
    private var stores: [URL: ReviewedHunksStore] = [:]
    private var radarWindows: [URL: AgentControlWindow] = [:]
    private var flightWindows: [URL: AgentControlWindow] = [:]
    private var arenaWindows: [URL: AgentArenaWindowController] = [:]
    private var queues: [URL: AgentControlQueue] = [:]
    public var onHookError: ((URL, String) -> Void)?

    public init(
        collisionRadar: CollisionRadarService = CollisionRadarService(),
        flightRecorder: FlightRecorderService = FlightRecorderService(),
        arena: AgentArenaService = AgentArenaService()
    ) {
        self.collisionRadar = collisionRadar
        self.flightRecorder = flightRecorder
        self.arena = arena
    }

    public func makeCollisionRadarViewController(for repositoryRoot: URL) -> CollisionRadarViewController {
        let presenter = CollisionRadarPresenter(service: collisionRadar, repositoryRoot: canonical(repositoryRoot))
        let controller = CollisionRadarViewController(presenter: presenter)
        radars.add(controller)
        return controller
    }

    public func presentCollisionRadar(for repositoryRoot: URL) {
        let root = canonical(repositoryRoot)
        if radarWindows[root] == nil {
            let controller = makeCollisionRadarViewController(for: root)
            let window = toolWindow(controller, root: root, name: "CollisionRadar")
            window.onClose = { [weak controller] in controller?.presenter.cancel() }
            radarWindows[root] = window
        }
        radarWindows[root]?.present()
    }

    public func makeFlightRecorderViewController(for repositoryRoot: URL) -> AgentFlightRecorderViewController {
        let presenter = FlightRecorderPresenter(service: flightRecorder, repositoryRoot: canonical(repositoryRoot))
        let controller = AgentFlightRecorderViewController(presenter: presenter)
        recorders.add(controller)
        return controller
    }

    public func presentFlightRecorder(for repositoryRoot: URL) {
        let root = canonical(repositoryRoot)
        if flightWindows[root] == nil {
            let controller = makeFlightRecorderViewController(for: root)
            let window = toolWindow(controller, root: root, name: "FlightRecorder")
            window.onClose = { [weak controller] in controller?.presenter.cancel() }
            flightWindows[root] = window
        }
        flightWindows[root]?.present()
    }

    private func toolWindow(_ controller: NSViewController, root: URL, name: String) -> AgentControlWindow {
        AgentControlWindow(
            content: controller, repositoryRoot: root, autosave: "Gita." + name + "Window",
            minimum: NSSize(width: 680, height: 400))
    }

    public func showArena(for repositoryRoot: URL, baseCommit: String = "HEAD") {
        let root = canonical(repositoryRoot)
        let window =
            arenaWindows[root]
            ?? AgentArenaWindowController(
                presenter: AgentArenaPresenter(service: arena, repositoryRoot: root))
        arenaWindows[root] = window
        if window.arena.presenter.canStart { window.arena.setup.setBase(baseCommit) }
        window.showWindow(nil)
    }

    public func makeReviewedHunksPresenter(for repositoryRoot: URL) -> ReviewedHunksPresenter {
        let root = canonical(repositoryRoot)
        let store = stores[root] ?? ReviewedHunksStore(storageURL: ReviewedHunksStore.defaultStorageURL(for: root))
        stores[root] = store
        let presenter = ReviewedHunksPresenter(store: store)
        presenter.didWrite = { [weak self, weak presenter] path in
            guard let self, let presenter else { return }
            for peer in self.reviews.allObjects where peer !== presenter && peer.store === store {
                peer.refresh(filePath: path)
            }
        }
        reviews.add(presenter)
        return presenter
    }

    public func makeReviewedHunksBar(presenter: ReviewedHunksPresenter) -> ReviewedHunksBarView {
        ReviewedHunksBarView(presenter: presenter)
    }

    public func handleHookEvent(_ event: AgentHookEvent, repositoryRoot: URL) {
        let root = canonical(repositoryRoot)
        let history = FlightHistory(service: flightRecorder, root: root)
        queue(for: root).append { [weak self, flightRecorder, resolver] in
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

    public func setFlightRecorderEnabled(_ enabled: Bool, for repositoryRoot: URL) {
        let root = canonical(repositoryRoot)
        queue(for: root).append { [weak self, flightRecorder] in
            await flightRecorder.setEnabled(enabled, for: root)
            if !Task.isCancelled { self?.refreshRecorders(for: root) }
        }
    }

    public func isFlightRecorderEnabled(for repositoryRoot: URL) async -> Bool {
        let root = canonical(repositoryRoot)
        await queues[root]?.last?.value
        return await flightRecorder.isEnabled(for: root)
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

    public var hasActiveRace: Bool {
        arenaWindows.values.contains { window in
            switch window.arena.presenter.state {
            case .racing, .cancelling: true
            default: false
            }
        }
    }

    public func cancelAll() {
        radars.allObjects.forEach { $0.presenter.cancel() }
        recorders.allObjects.forEach { $0.presenter.cancel() }
        reviews.allObjects.forEach { $0.cancel() }
    }
}
