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
            String(localized: "All (+ Untracked)"), String(localized: "Tracked Only"),
            String(localized: "Staged Only"), String(localized: "Selected (\(selectedPaths.count))"),
        ]
    }
    var scopeSymbols: [String] { ["tray.full", "doc.text", "checkmark.circle", "checklist"] }
    var isRunning: Bool { state == .running }
    var canKeepIndex: Bool { scope != .stagedOnly && !isRunning }
    var request: StashCreateRequest { StashCreateRequest(message: message, scope: scope, keepIndex: keepIndex) }
    var affectedChanges: [FileChange] {
        switch scope {
        case .allIncludingUntracked: changes
        case .trackedOnly: changes.filter { !$0.isUntracked }
        case .stagedOnly: changes.filter(\.isStaged)
        case .selectedPaths(let paths):
            changes.filter { change in
                paths.contains { change.path == $0 || change.path.hasPrefix($0 + "/") }
            }
        }
    }
    var fileCountText: String {
        let count = affectedChanges.count
        return count == 1 ? String(localized: "1 file") : String(localized: "\(count) files")
    }
    var canSubmit: Bool {
        !isRunning && !affectedChanges.isEmpty && (try? request.validate()) != nil
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
