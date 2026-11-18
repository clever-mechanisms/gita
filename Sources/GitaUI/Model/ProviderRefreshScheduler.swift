import Foundation

/// A repository's three timers: the minute tick (dirty working tree, providers), the agents' 10-second tick and
/// Vercel's 15-second tick. The handlers decide what each tick does; `stop` (or releasing the scheduler) ends them.
@MainActor
final class ProviderRefreshScheduler {
    struct Handlers {
        var minute: @MainActor () -> Void
        var agents: @MainActor () -> Void
        var vercel: @MainActor () -> Void
    }

    private struct Cadence {
        let interval: TimeInterval
        let tolerance: TimeInterval
    }
    private static let minute = Cadence(interval: 60, tolerance: 8)
    private static let agents = Cadence(interval: 10, tolerance: 2)
    private static let vercel = Cadence(interval: 15, tolerance: 3)

    private var timers: [Timer] = []

    func start(_ handlers: Handlers) {
        stop()
        timers = [
            Self.schedule(Self.minute, handlers.minute), Self.schedule(Self.agents, handlers.agents),
            Self.schedule(Self.vercel, handlers.vercel),
        ]
    }

    func stop() {
        for timer in timers { timer.invalidate() }
        timers = []
    }

    isolated deinit { stop() }

    private static func schedule(_ cadence: Cadence, _ handler: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer.scheduledTimer(withTimeInterval: cadence.interval, repeats: true) { _ in
            MainActor.assumeIsolated { handler() }
        }
        timer.tolerance = cadence.tolerance
        return timer
    }
}
