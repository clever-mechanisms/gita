import Foundation

/// How long one Git command may run. Local reads and writes get a fixed deadline; network transfers and commands
/// that run the user's hooks have no fixed deadline (a large push or a hook running a test suite can take as long as
/// it takes) and end only when cancelled or after `idleLimit` without any output.
struct GitTimeout: Sendable, Equatable, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral {
    static let standard = Self(CommandRequest.defaultTimeout)
    /// Long enough for a silent hook or a slow server, short enough that a stalled connection ends on its own.
    static let idleLimit: TimeInterval = 600
    /// Network transfers and hook-running commands.
    static let untilIdle = Self(seconds: idleLimit, restartsOnOutput: true)

    let seconds: TimeInterval
    let restartsOnOutput: Bool

    init(_ seconds: TimeInterval) { self.init(seconds: seconds, restartsOnOutput: false) }
    init(integerLiteral value: Int) { self.init(TimeInterval(value)) }
    init(floatLiteral value: Double) { self.init(value) }

    private init(seconds: TimeInterval, restartsOnOutput: Bool) {
        self.seconds = seconds
        self.restartsOnOutput = restartsOnOutput
    }

    func apply(to request: inout CommandRequest) {
        request.timeout = seconds
        request.timeoutRestartsOnOutput = restartsOnOutput
    }
}
