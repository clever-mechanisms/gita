import Foundation

/// What production actually serves, the stable per-branch preview URLs and unresolved preview comments.
/// Display metadata only: no environment, claims or build resources.
public struct VercelContext: Sendable, Hashable {
    public struct Production: Sendable, Hashable {
        public var deploymentID: String
        /// Immutable deployment host, matching the listed deployment's URL.
        public var url: URL?
        /// Production domains (custom domains and the project's `.vercel.app` production alias).
        public var domains: [URL]
        public var commit: String?
        public var branch: String?
        /// Production is pinned to an older deployment than the latest production build (rollback or promote).
        public var isPinned: Bool
        public var latestCommit: String?
        public var createdAt: Date?

        public init(
            deploymentID: String, url: URL? = nil, domains: [URL] = [], commit: String? = nil, branch: String? = nil,
            isPinned: Bool = false, latestCommit: String? = nil, createdAt: Date? = nil
        ) {
            self.deploymentID = deploymentID
            self.url = url
            self.domains = domains
            self.commit = commit
            self.branch = branch
            self.isPinned = isPinned
            self.latestCommit = latestCommit
            self.createdAt = createdAt
        }

        /// The address people use: the first custom domain, else the project's `.vercel.app` production alias.
        public var primaryDomain: URL? {
            domains.first { $0.host?.lowercased().hasSuffix(".vercel.app") == false } ?? domains.first
        }
    }

    public struct Comments: Sendable, Hashable {
        public var byBranch: [String: Int]
        /// One thread's page, used when a branch has exactly one unresolved thread.
        public var threadURLs: [String: URL]

        public init(byBranch: [String: Int] = [:], threadURLs: [String: URL] = [:]) {
            self.byBranch = byBranch
            self.threadURLs = threadURLs
        }
    }

    public var production: Production?
    public var productionBranch: String?
    /// Branch name to its stable preview URL (`<project>-git-<branch>-<scope>.vercel.app`).
    public var branchPreviews: [String: URL]
    /// Branch name to the host of the deployment its preview URL serves now.
    public var branchPreviewTargets: [String: String] = [:]
    public var comments: Comments?
    /// Identity of the listed deployments this context was derived from; a change triggers a new read.
    public var fingerprint: String
    public var readAt: Date

    public init(
        production: Production? = nil, productionBranch: String? = nil, branchPreviews: [String: URL] = [:],
        comments: Comments? = nil, fingerprint: String = "", readAt: Date = Date()
    ) {
        self.production = production
        self.productionBranch = productionBranch
        self.branchPreviews = branchPreviews
        self.comments = comments
        self.fingerprint = fingerprint
        self.readAt = readAt
    }

    public static func fingerprint(_ items: [ProviderItem]) -> String {
        items.filter { $0.kind == .deployment }.map { "\($0.id)=\($0.state.rawValue)" }.joined(separator: "|")
    }

    /// Where Open goes for a listed deployment: the production domain while it is live, the branch's stable preview URL
    /// while that alias serves it, else the deployment's own host (the only address that shows that exact build).
    public func primaryURL(for item: ProviderItem) -> URL? {
        guard item.kind == .deployment else { return item.url }
        if isLive(item), let production { return production.primaryDomain ?? production.url ?? item.url }
        if let branch = item.branch, let url = branchPreviews[branch], let host = item.url?.host?.lowercased(),
            branchPreviewTargets[branch] == host
        {
            return url
        }
        return item.url
    }

    /// The listed deployment production serves, matched by immutable host.
    public func isLive(_ item: ProviderItem) -> Bool {
        guard let host = production?.url?.host?.lowercased(), item.kind == .deployment else { return false }
        return item.url?.host?.lowercased() == host
    }
}
