import Foundation
import GitaCore

/// The `brew install`s running, kept by the guide rather than by one checklist: going Back and on to the Tools step
/// builds a new checklist, which must show an install still running as Installing… and never offer a second one
/// that would wait on Homebrew's lock. Each install is left to finish even if the guide closes meanwhile: stopping
/// Homebrew halfway leaves it locked.
@MainActor
final class SetupInstalls {
    /// How an install ended: nil when it worked, else the last lines it printed.
    typealias Finished = @MainActor (SetupTool, _ failure: String?) -> Void

    private var running: Set<SetupTool> = []
    /// The checklists on screen, told when an install ends.
    private var listeners: [ObjectIdentifier: Finished] = [:]

    func isRunning(_ tool: SetupTool) -> Bool { running.contains(tool) }

    /// Runs `install` for `tool` unless one is already running; false then.
    @discardableResult
    func start(_ tool: SetupTool, _ install: @escaping @Sendable (SetupTool) async throws -> CommandResult) -> Bool {
        guard running.insert(tool).inserted else { return false }
        Task { [weak self] in
            let failure: String?
            do {
                let result = try await install(tool)
                failure =
                    result.exitCode == 0 ? nil : Self.lastLines(result.stderr.isEmpty ? result.stdout : result.stderr)
            } catch { failure = error.localizedDescription }
            self?.finish(tool, failure: failure)
        }
        return true
    }

    func listen(_ owner: AnyObject, _ finished: @escaping Finished) { listeners[ObjectIdentifier(owner)] = finished }
    func stopListening(_ owner: AnyObject) { listeners[ObjectIdentifier(owner)] = nil }

    private func finish(_ tool: SetupTool, failure: String?) {
        running.remove(tool)
        for finished in listeners.values { finished(tool, failure) }
    }

    nonisolated static func lastLines(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).suffix(4).joined(separator: "\n")
    }
}

/// One tool row's lifecycle in a checklist: its first check, or the last answer, which a recheck leaves on screen
/// until the next answer, or a command from the row's button still running (the Command Line Tools installer, Set
/// Identity), which holds the button so a second click starts nothing. A `brew install` is not here: it outlives
/// the page, so `SetupInstalls` holds it.
enum SetupToolPhase: Equatable {
    case checking
    case checked(SetupToolState)
    case working(SetupToolState?)

    var state: SetupToolState? {
        switch self {
        case .checking: nil
        case .checked(let state): state
        case .working(let state): state
        }
    }
    var isWorking: Bool { if case .working = self { true } else { false } }

    /// A check answered; a command still running keeps the button held.
    func answered(_ state: SetupToolState) -> Self { isWorking ? .working(state) : .checked(state) }
    /// The button's command started.
    var started: Self { .working(state) }
    /// The button's command returned.
    var finished: Self { state.map(Self.checked) ?? .checking }
}
