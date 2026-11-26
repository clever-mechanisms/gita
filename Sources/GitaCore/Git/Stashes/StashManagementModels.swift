import Foundation

public enum StashScope: Sendable, Hashable {
    case allIncludingUntracked
    case trackedOnly
    case stagedOnly
    case selectedPaths([String])
}

public struct StashCreateRequest: Sendable, Hashable {
    public var message: String
    public var scope: StashScope
    public var keepIndex: Bool

    public init(message: String = "", scope: StashScope = .allIncludingUntracked, keepIndex: Bool = false) {
        self.message = message
        self.scope = scope
        self.keepIndex = keepIndex
    }
}

public enum StashPopOutcome: Sendable, Equatable {
    case applied
    case conflictedStashKept(String)
    case indexConflictRetryWithoutIndex(String)
}

public enum StashManagementError: Error, LocalizedError, Sendable {
    case emptySelectedPaths
    case keepIndexUnsupportedForStagedOnly
    case noChangesToStash

    public var errorDescription: String? {
        switch self {
        case .emptySelectedPaths: String(localized: "Select at least one file to stash.")
        case .keepIndexUnsupportedForStagedOnly: String(localized: "Turn off Keep Index to stash staged changes.")
        case .noChangesToStash: String(localized: "There are no changes to stash in this scope.")
        }
    }
}
