import Foundation

/// Git could not apply a remote change. Git's own diagnostic is withheld: it can contain credentials.
enum RemoteCommandError: Error, LocalizedError, Sendable {
    case addFailed
    case setURLFailed
    case renameFailed
    case removeFailed
    case fetchFailed

    var errorDescription: String? {
        switch self {
        case .addFailed: String(localized: "Git could not add the local remote configuration. Reload the remote list.")
        case .setURLFailed: String(localized: "Git could not change the local fetch URL. Reload the remote list.")
        case .renameFailed:
            String(localized: "Git could not rename the remote. Reload the configuration and tracking references.")
        case .removeFailed:
            String(
                localized: """
                    Git could not remove the local remote configuration. Reload the configuration and tracking \
                    references.
                    """)
        case .fetchFailed:
            String(localized: "Git could not fetch this remote. Check its URL and existing CLI access, then refresh.")
        }
    }
}
