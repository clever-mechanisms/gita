import Foundation

public enum VisualPreviewDiffMode: String, CaseIterable, Sendable, Equatable {
    case curtain, onionSkin, sideBySide
}

public enum VisualPreviewViewport: String, CaseIterable, Sendable, Equatable {
    case desktop, laptop, tablet, mobile, responsive

    public var size: CGSize? {
        switch self {
        case .desktop: CGSize(width: 1440, height: 900)
        case .laptop: CGSize(width: 1280, height: 800)
        case .tablet: CGSize(width: 768, height: 1024)
        case .mobile: CGSize(width: 390, height: 844)
        case .responsive: nil
        }
    }
}

public struct VisualPreviewPair: Sendable, Equatable {
    public let productionURL: URL
    public let previewURL: URL
    public let title: String

    public init(productionURL: URL, previewURL: URL, title: String) {
        self.productionURL = productionURL
        self.previewURL = previewURL
        self.title = title
    }
}

public enum VisualPreviewURLValidator {
    public static func validatedHTTPSURL(_ url: URL?) -> URL? {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
            url.user == nil, url.password == nil, !host.contains("\\")
        else { return nil }
        return url
    }

    public static func normalizedRoute(_ rawRoute: String) -> String {
        let input = rawRoute.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        guard !input.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
            let parts = URLComponents(string: input)
        else { return "/" }
        var path = "/" + parts.percentEncodedPath.drop(while: { $0 == "/" })
        if let query = parts.percentEncodedQuery { path += "?" + query }
        if let fragment = parts.percentEncodedFragment { path += "#" + fragment }
        return path
    }

    public static func resolvedURL(base: URL, route: String) -> URL? {
        guard let origin = validatedHTTPSURL(base),
            var parts = URLComponents(url: origin, resolvingAgainstBaseURL: true),
            let suffix = URLComponents(string: normalizedRoute(route))
        else { return nil }
        parts.percentEncodedPath = suffix.percentEncodedPath
        parts.percentEncodedQuery = suffix.percentEncodedQuery
        parts.percentEncodedFragment = suffix.percentEncodedFragment
        guard let target = validatedHTTPSURL(parts.url), target.host == origin.host, target.port == origin.port
        else { return nil }
        return target
    }

    public static func resolvePair(
        vercelContext: VercelContext?, previewDeployment: DeploymentDetail?
    ) -> VisualPreviewPair? {
        guard let context = vercelContext, let production = context.production, let detail = previewDeployment,
            production.deploymentID != detail.id
        else { return nil }
        let live =
            validatedHTTPSURL(production.primaryDomain)
            ?? production.domains.lazy.compactMap(validatedHTTPSURL).first ?? validatedHTTPSURL(production.url)
        let preview = previewURL(for: detail, in: context)
        guard let live, let preview, live != preview else { return nil }
        return VisualPreviewPair(
            productionURL: live, previewURL: preview,
            title: String(localized: "\(detail.projectName) · Visual comparison"))
    }
    private static func previewURL(for detail: DeploymentDetail, in context: VercelContext) -> URL? {
        let immutable = validatedHTTPSURL(detail.previewURL)
        if let branch = detail.branch, let host = immutable?.host?.lowercased(),
            context.branchPreviewTargets[branch] == host, let stable = validatedHTTPSURL(context.branchPreviews[branch])
        {
            return stable
        }
        return immutable ?? detail.aliases.lazy.compactMap(validatedHTTPSURL).first
    }
}

public enum VisualPreviewDiffState: Sendable, Equatable {
    case idle
    case loading(productionLoaded: Bool, previewLoaded: Bool)
    case ready
    case failed(String)
}
