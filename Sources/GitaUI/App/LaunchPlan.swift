import Foundation

/// What a launch opens: the tab session (saved, plus repositories asked for), and whether the setup guide is due.
struct LaunchPlan {
    struct Inputs {
        var arguments: [String]
        var isDevelopment: Bool
        var background: Bool
        var pendingURLs: [URL]
        var commandLineRepository: URL?
        var saved: RepositoryTabSession?
        var hasStoredSession: Bool
        var recent: [String]
        /// The setup guide version last shown; nil when never stored.
        var storedGuideVersion: Int?
    }

    /// The guide should count as seen: an update must not interrupt someone already using repositories.
    var marksGuideSeen: Bool
    /// An interactive first launch with nothing to open: the setup guide opens with the window.
    var initialSetupPending: Bool
    var session: RepositoryTabSession

    init(_ inputs: Inputs) {
        marksGuideSeen = inputs.storedGuideVersion == nil && (inputs.hasStoredSession || !inputs.recent.isEmpty)
        let guideVersion = marksGuideSeen ? SetupGuideState.version : inputs.storedGuideVersion ?? 0
        initialSetupPending =
            !inputs.isDevelopment && !inputs.background && inputs.arguments.count == 1 && inputs.pendingURLs.isEmpty
            && guideVersion < SetupGuideState.version && (inputs.saved?.repositories.isEmpty ?? true)
            && inputs.recent.isEmpty
        var session = inputs.saved ?? RepositoryTabSession()
        if let requested = inputs.commandLineRepository { session.focus(requested) }
        for url in inputs.pendingURLs where url.isFileURL { session.focus(url) }
        if session.repositories.isEmpty, inputs.saved == nil, let recent = inputs.recent.first {
            session.focus(URL(fileURLWithPath: recent))
        }
        self.session = session
    }
}
