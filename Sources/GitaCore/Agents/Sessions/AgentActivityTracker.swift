import Foundation

/// Working/idle inference from cumulative CPU time, with hysteresis in both level and time so a terminal redraw
/// does not flash "working" and a pause between tool calls does not flash "done".
///
/// * Starts working when the CPU rate over at least `window` seconds reaches `startFraction` of one core.
/// * Stays working while the rate stays at or above `sustainFraction`.
/// * Stops after `quietPeriod` seconds without such an interval. A stop after at least `minimumWork` seconds of
///   work is a finished turn (`.finished`); a shorter burst just returns to idle (`.settled`).
public struct AgentActivityTracker: Sendable, Hashable {
    public struct Configuration: Sendable, Hashable {
        /// Measured on Claude Code 2.1 sessions: an idle TUI uses 0.2–2.6 % of a core in 5 s windows, one waiting on
        /// the model 2.8–4.2 %, one streaming or running tools well above. Codex idles at 0 %.
        public var startFraction = 0.035
        public var sustainFraction = 0.025
        public var window: TimeInterval = 6
        /// Before the first decision a shorter span is enough, so a freshly seen process is classified on the second
        /// sample.
        public var bootstrapWindow: TimeInterval = 1
        public var quietPeriod: TimeInterval = 20
        public var minimumWork: TimeInterval = 10
        public init() {}
    }

    public enum Transition: Sendable, Hashable { case started, finished, settled }

    /// Where the inference stands. Working carries when it began and the last sample active enough to keep it, so
    /// the length of a turn is always known.
    public enum Phase: Sendable, Hashable {
        /// Not enough samples yet for a first rate.
        case undecided
        case idle
        case working(since: TimeInterval, lastActive: TimeInterval)
    }

    public let configuration: Configuration
    private var samples: [Sample] = []
    public private(set) var phase = Phase.undecided
    /// The latest sample whose window reached `sustainFraction`, working or not (a model wait keeps this fresh).
    public private(set) var lastBusy: TimeInterval?

    public var hasDecided: Bool { phase != .undecided }
    public var isWorking: Bool { workingSince != nil }
    public var workingSince: TimeInterval? {
        if case .working(let since, _) = phase { since } else { nil }
    }

    private struct Sample: Sendable, Hashable {
        var time: TimeInterval
        var cpu: Double
    }

    public init(configuration: Configuration = Configuration()) { self.configuration = configuration }

    /// `time` is any monotonic clock in seconds; `cpu` is cumulative CPU seconds (never decreasing).
    @discardableResult
    public mutating func add(time: TimeInterval, cpu: Double) -> Transition? {
        if let last = samples.last, time <= last.time { return nil }
        samples.append(Sample(time: time, cpu: max(cpu, samples.last?.cpu ?? cpu)))
        let span = hasDecided ? configuration.window : configuration.bootstrapWindow
        // The newest sample at least `span` old is the reference; keep it and everything after.
        guard let referenceIndex = samples.lastIndex(where: { time - $0.time >= span }) else { return nil }
        if referenceIndex > 0 { samples.removeFirst(referenceIndex) }
        let reference = samples[0]
        let current = samples[samples.count - 1]
        let rate = (current.cpu - reference.cpu) / (current.time - reference.time)
        if rate >= configuration.sustainFraction { lastBusy = time }
        let working = workingSince
        if rate >= configuration.startFraction || (working != nil && rate >= configuration.sustainFraction) {
            phase = .working(since: working ?? time, lastActive: time)
            return working == nil ? .started : nil
        }
        guard case .working(let since, let lastActive) = phase else {
            phase = .idle
            return nil
        }
        guard time - lastActive >= configuration.quietPeriod else { return nil }
        phase = .idle
        return lastActive - since >= configuration.minimumWork ? .finished : .settled
    }
}
