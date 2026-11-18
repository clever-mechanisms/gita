import Foundation

/// The native rebase editor or its session files could not be used.
enum RebaseEditorError: Error, LocalizedError, Sendable {
    case editorUnavailable
    case invalidInvocation
    case notPrepared
    case sessionNotRemoved

    var errorDescription: String? {
        switch self {
        case .editorUnavailable: String(localized: "The native rebase editor executable is unavailable.")
        case .invalidInvocation: String(localized: "Invalid native rebase editor invocation.")
        case .notPrepared:
            String(localized: "The native rebase did not finish preparing its plan. Abort it before starting again.")
        case .sessionNotRemoved: String(localized: "Could not remove the completed rebase session.")
        }
    }
}
