import Foundation

/// Where a clicked notification leads, encoded once into its `userInfo` and decoded once from it.
enum NotificationRoute: Equatable, Sendable {
    /// A provider fact (run, deployment, pull request), validated on the way in and out.
    case provider(ProviderNotificationDestination)
    /// An agent's terminal, else its checkout or repository.
    case agent(session: String?, repository: String?, checkout: String?)
    /// A Vercel alert: its page on vercel.com when known, else the repository.
    case vercelAlert(repository: String?, url: URL?)
    /// A sample sent from Settings ▸ Notifications; a click only dismisses it.
    case test
    /// A notification whose payload is missing or no longer valid.
    case unsupported

    static let agentKey = "gitaAgentV1"
    static let alertKey = "gitaVercelAlertV1"
    static let testKey = "gitaTestV1"
    private enum Field {
        static let session = "session", repository = "repository", checkout = "checkout", url = "url"
    }

    /// The `userInfo` carrying this route; empty when a provider destination fails validation.
    var userInfo: [String: Any] {
        switch self {
        case .provider(let destination):
            return ProviderNotificationPayload.encode(destination).map { [ProviderNotificationPayload.userInfoKey: $0] }
                ?? [:]
        case .agent(let session, let repository, let checkout):
            let fields = [Field.session: session, Field.repository: repository, Field.checkout: checkout]
            return [Self.agentKey: fields.compactMapValues { $0 }]
        case .vercelAlert(let repository, let url):
            return [Self.alertKey: [Field.repository: repository ?? "", Field.url: url?.absoluteString ?? ""]]
        case .test:
            return [Self.testKey: true]
        case .unsupported:
            return [:]
        }
    }

    init(userInfo: [AnyHashable: Any]) {
        if userInfo[Self.testKey] as? Bool == true {
            self = .test
        } else if let agent = userInfo[Self.agentKey] as? [String: String] {
            self = .agent(
                session: agent[Field.session], repository: agent[Field.repository], checkout: agent[Field.checkout])
        } else if let alert = userInfo[Self.alertKey] as? [String: String] {
            self = .vercelAlert(repository: alert[Field.repository], url: alert[Field.url].flatMap(Self.vercelPage))
        } else if let data = userInfo[ProviderNotificationPayload.userInfoKey] as? Data,
            let destination = ProviderNotificationPayload.decode(data)
        {
            self = .provider(destination)
        } else {
            self = .unsupported
        }
    }

    /// Only Vercel's own pages; anything else falls back to showing the repository.
    static func vercelPage(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme == "https", url.host?.lowercased() == "vercel.com" else {
            return nil
        }
        return url
    }

    /// A path a route may open: absolute, bounded, without NUL.
    static func folder(_ path: String?) -> URL? {
        guard let path, path.hasPrefix("/"), path.utf8.count <= 4_096, !path.contains("\0") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
