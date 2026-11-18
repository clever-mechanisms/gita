import Foundation

/// Calls back once a frame (60 a second) on the main run loop, in every mode, while running; for the illustrations
/// that play by themselves.
@MainActor
final class FrameTicker {
    private static let interval: TimeInterval = 1.0 / 60
    private var timer: Timer?
    var isRunning: Bool { timer != nil }

    /// Starts calling `tick`; does nothing while already running.
    func start(_ tick: @escaping @MainActor () -> Void) {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { _ in MainActor.assumeIsolated { tick() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    func stop() {
        timer?.invalidate()
        timer = nil
    }
    isolated deinit { timer?.invalidate() }
}
