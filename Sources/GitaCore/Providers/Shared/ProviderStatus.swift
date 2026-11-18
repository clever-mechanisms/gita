import Foundation

/// A provider's connection status for one repository (`ProviderReport`) or one detail read (`ProviderDetailReport`,
/// `VercelBuildLog`). Raw values are the English tokens the logs and the string catalog use.
public enum ProviderStatus: String, Sendable, Hashable {
    case connected = "Connected"
    case partial = "Partial"
    case unavailable = "Unavailable"
    case noRemote = "No remote"
    case notGitHub = "Not GitHub"
    case notLinked = "Not linked"
    case notInstalled = "Not installed"
    case offline = "Offline"
    case signInRequired = "Sign in required"
    case accessDenied = "Access denied"
    case timedOut = "Timed out"
    case responseTooLarge = "Response too large"
    case updateCLI = "Update CLI"
    case projectChanged = "Project changed"
    case repositoryChanged = "Repository changed"
    case cancelled = "Cancelled"

    /// A provider that is actually broken for a repository, worth a line in the menu bar panel.
    public var isBroken: Bool {
        switch self {
        case .signInRequired, .accessDenied, .notInstalled, .offline, .timedOut, .unavailable, .updateCLI,
            .responseTooLarge, .projectChanged:
            true
        case .connected, .partial, .noRemote, .notGitHub, .notLinked, .repositoryChanged, .cancelled: false
        }
    }

    public var localizedTitle: String { Self.titles[self] ?? rawValue }

    private static let titles: [Self: String] = [
        .connected: String(localized: "Connected"),
        .partial: String(localized: "Partial"),
        .unavailable: String(localized: "Unavailable"),
        .noRemote: String(localized: "No remote"),
        .notGitHub: String(localized: "Not GitHub"),
        .notLinked: String(localized: "Not linked"),
        .notInstalled: String(localized: "Not installed"),
        .offline: String(localized: "Offline"),
        .signInRequired: String(localized: "Sign in required"),
        .accessDenied: String(localized: "Access denied"),
        .timedOut: String(localized: "Timed out"),
        .responseTooLarge: String(localized: "Response too large"),
        .updateCLI: String(localized: "Update CLI"),
        .projectChanged: String(localized: "Project changed"),
        .repositoryChanged: String(localized: "Repository changed"),
        .cancelled: String(localized: "Cancelled"),
    ]
}

extension ProviderReport {
    init(
        _ provider: ProviderKind, items: [ProviderItem] = [], status: ProviderStatus, diagnostic: String? = nil,
        sourceID: String? = nil
    ) {
        self.init(provider: provider, items: items, status: status, diagnostic: diagnostic, sourceID: sourceID)
    }

    init(_ provider: ProviderKind, failure: ProviderFailure) {
        self.init(provider, status: failure.status, diagnostic: failure.diagnostic)
    }
}
