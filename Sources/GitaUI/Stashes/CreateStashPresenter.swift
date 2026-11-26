import Foundation
import GitaCore

enum CreateStashState: Equatable, Sendable {
    case idle
    case running
    case failed(String)
}

struct CreateStashPresenter: Sendable {
    let changes: [FileChange]
    let selectedPaths: [String]
    private(set) var state = CreateStashState.idle
    private(set) var scope = StashScope.allIncludingUntracked
    var message = ""
    private(set) var keepIndex = false

    var scopes: [StashScope] { [.allIncludingUntracked, .trackedOnly, .stagedOnly, .selectedPaths(selectedPaths)] }
    var scopeTitles: [String] {
        [
            String(localized: "All Changes (Incl. Untracked)"), String(localized: "Tracked Only"),
            String(localized: "Staged Only"), String(localized: "Selected Files (\(selectedPaths.count))"),
        ]
    }
    var isRunning: Bool { state == .running }
    var canKeepIndex: Bool { scope != .stagedOnly && !isRunning }
    var request: StashCreateRequest { StashCreateRequest(message: message, scope: scope, keepIndex: keepIndex) }
    var affectedPaths: [String] {
        switch scope {
        case .allIncludingUntracked: changes.map(\.path)
        case .trackedOnly: changes.filter { !$0.isUntracked }.map(\.path)
        case .stagedOnly: changes.filter(\.isStaged).map(\.path)
        case .selectedPaths(let paths):
            changes.filter { change in
                paths.contains { change.path == $0 || change.path.hasPrefix($0 + "/") }
            }.map(\.path)
        }
    }
    var canSubmit: Bool {
        !isRunning && !affectedPaths.isEmpty && (try? request.validate()) != nil
    }
    var summary: String {
        let paths = affectedPaths
        let count = String(localized: "Affected files: \(paths.count)")
        return ([count] + Array(paths.prefix(4))).joined(separator: "\n")
    }
    var status: SheetStatus {
        switch state {
        case .idle: SheetStatus(message: "")
        case .running: SheetStatus(message: String(localized: "Creating stash…"), isBusy: true)
        case .failed(let message): SheetStatus(message: message, isError: true)
        }
    }

    mutating func selectScope(_ choice: StashScope) {
        guard !isRunning, scopes.contains(choice), choice != .selectedPaths([]) else { return }
        scope = choice
        if scope == .stagedOnly { keepIndex = false }
        state = .idle
    }
    mutating func setKeepIndex(_ value: Bool) { keepIndex = value && canKeepIndex }
    mutating func begin() -> StashCreateRequest? {
        guard canSubmit else { return nil }
        state = .running
        return request
    }
    mutating func finish() { state = .idle }
    mutating func fail(_ message: String) { state = .failed(message) }
}
