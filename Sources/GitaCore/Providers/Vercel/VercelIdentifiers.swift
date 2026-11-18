import Foundation

/// Vercel identifiers that become command arguments or API paths, validated once.
enum VercelIdentifiers {
    private static let maximumHost = 253
    private static let maximumLabel = 63

    /// An immutable deployment id (`dpl_…`).
    static func isDeploymentID(_ value: String) -> Bool {
        value.hasPrefix("dpl_") && ProviderValidation.isSlug(value)
    }

    static func deploymentID(_ value: String?) -> String? {
        value.flatMap { isDeploymentID($0) ? $0 : nil }
    }

    /// A project id (`prj_…`).
    static func isProjectID(_ value: String) -> Bool {
        value.hasPrefix("prj_") && value.count > 4 && ProviderValidation.isSlug(value)
    }

    /// A team or account scope given to `--scope`; nil means the linked default.
    static func isScope(_ scope: String?) -> Bool {
        scope.map(ProviderValidation.isSlug) ?? true
    }

    static func scopeArguments(_ scope: String?) -> [String] {
        scope.map { ["--scope", $0] } ?? []
    }

    /// A deployment reference: its id, or its host (bare or as a plain `https://host` URL), lowercased.
    static func deploymentReference(_ value: String) -> String? {
        if isDeploymentID(value) { return value }
        let address = value.hasPrefix("https://") ? value : "https://" + value
        guard let url = URLComponents(string: address), isBareHTTPS(url), let host = url.host, isDNSName(host) else {
            return nil
        }
        return host.lowercased()
    }

    private static func isBareHTTPS(_ url: URLComponents) -> Bool {
        url.scheme == "https" && url.user == nil && url.password == nil && url.port == nil && url.query == nil
            && url.fragment == nil && (url.path.isEmpty || url.path == "/")
    }

    private static func isDNSName(_ host: String) -> Bool {
        host.contains(".") && host.utf8.count <= maximumHost
            && host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy(isDNSLabel)
    }

    private static func isDNSLabel(_ label: Substring) -> Bool {
        !label.isEmpty && label.count <= maximumLabel && !label.hasPrefix("-") && !label.hasSuffix("-")
            && ProviderValidation.consists(label, of: ProviderValidation.hostLabelCharacters)
    }

    /// The validated identity of a listed deployment, or nil.
    static func deploymentTarget(reference: String, projectName: String?, scope: String?) -> ProviderTarget? {
        guard let reference = deploymentReference(reference), let projectName, ProviderValidation.isSlug(projectName),
            isScope(scope)
        else { return nil }
        return .deployment(reference: reference, projectName: projectName, scope: scope)
    }
}
