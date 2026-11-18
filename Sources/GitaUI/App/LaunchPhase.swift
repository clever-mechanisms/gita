/// Where the shell's launch is. Until `launched`, requests wait: URLs in the router, a notification's result in the
/// shell's attention, the window here (`wantsWindow`); a built-in terminal or an author tab is refused (`ShellGate`).
enum LaunchPhase {
    /// `applicationDidFinishLaunching` has not finished the launch yet.
    case starting(wantsWindow: Bool)
    /// A replacement started for a language restart waits for its predecessor to quit.
    case waitingForPredecessor(Task<Void, Never>, wantsWindow: Bool)
    case launched

    var isLaunched: Bool {
        if case .launched = self { true } else { false }
    }

    /// Something asked for the window before launch: it opens with the launch, even a background one.
    var wantsWindow: Bool {
        switch self {
        case .starting(let wants), .waitingForPredecessor(_, let wants): wants
        case .launched: false
        }
    }

    mutating func requestWindow() {
        switch self {
        case .starting: self = .starting(wantsWindow: true)
        case .waitingForPredecessor(let task, _): self = .waitingForPredecessor(task, wantsWindow: true)
        case .launched: break
        }
    }

    /// Stops waiting for the predecessor (the app quits).
    func cancel() {
        if case .waitingForPredecessor(let task, _) = self { task.cancel() }
    }
}
