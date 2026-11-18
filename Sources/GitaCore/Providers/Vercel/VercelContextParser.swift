import Foundation

/// The project, alias and comment reads behind `VercelContext`, and the rule that combines them.
enum VercelContextParser {
    struct Project: Sendable {
        var productionBranch: String?
        var target: Target?
        /// The latest alias request (promote or rollback): its deployment and whether it succeeded.
        var aliasRequest: (to: String, succeeded: Bool)?
    }

    /// The latest production build.
    struct Target: Sendable {
        var id: String
        var host: String?
        var aliases: [String]
        var commit: String?
        var branch: String?
        var createdAt: Date?
    }

    struct Alias: Sendable {
        var host: String
        var deploymentID: String
        var deploymentHost: String?
    }

    private static let aliasLimit = 100
    private static let aliasListLimit = 200
    private static let threadLimit = 100

    static func project(_ data: Data, projectID: String) throws -> Project {
        let row = try JSONDecoder().decode(RawProject.self, from: data)
        guard row.id == projectID else { throw ProviderResponseError.shape }
        var request: (String, Bool)?
        if let raw = row.lastAliasRequest, let to = VercelIdentifiers.deploymentID(raw.toDeploymentId) {
            request = (to, raw.jobStatus?.lowercased() == "succeeded")
        }
        return Project(
            productionBranch: ProviderValidation.bounded(row.link?.productionBranch),
            target: row.targets?.production.flatMap(target), aliasRequest: request)
    }

    private static func target(_ production: RawTarget) -> Target? {
        guard let id = VercelIdentifiers.deploymentID(production.id) else { return nil }
        return Target(
            id: id, host: production.url.flatMap(VercelIdentifiers.deploymentReference),
            aliases: production.alias.prefix(aliasLimit).compactMap(VercelIdentifiers.deploymentReference),
            commit: production.meta?.commit, branch: production.meta?.branch,
            createdAt: ProviderDates.positiveMilliseconds(production.createdAt))
    }

    static func aliases(_ data: Data) throws -> [Alias] {
        try JSONDecoder().decode(RawAliases.self, from: data).aliases.prefix(aliasListLimit).compactMap { row in
            guard let host = VercelIdentifiers.deploymentReference(row.alias ?? ""), !host.hasPrefix("dpl_"),
                let id = VercelIdentifiers.deploymentID(row.deploymentId ?? row.deployment?.id)
            else { return nil }
            return Alias(
                host: host, deploymentID: id,
                deploymentHost: row.deployment?.url.flatMap(VercelIdentifiers.deploymentReference))
        }
    }

    static func comments(_ data: Data, projectID: String) throws -> VercelContext.Comments {
        let rows = try JSONDecoder().decode(RawComments.self, from: data)
        guard rows.scope?.projectId == nil || rows.scope?.projectId == projectID else {
            throw ProviderResponseError.shape
        }
        var comments = VercelContext.Comments()
        for thread in rows.threads.prefix(threadLimit) where !thread.resolved {
            guard let branch = ProviderValidation.bounded(thread.branch) else { continue }
            comments.byBranch[branch, default: 0] += 1
            // A single thread opens directly; several open the branch's preview instead.
            comments.threadURLs[branch] =
                comments.byBranch[branch] == 1 ? ProviderValidation.safeWebURL(thread.webUrl ?? thread.url) : nil
        }
        return comments
    }

    // MARK: Raw shapes (selective)

    private struct RawProject: Decodable {
        struct Link: Decodable { var productionBranch: String? }
        struct Targets: Decodable { var production: RawTarget? }
        struct AliasRequest: Decodable {
            var toDeploymentId: String?
            var jobStatus: String?
        }

        var id: String
        var link: Link?
        var targets: Targets?
        var lastAliasRequest: AliasRequest?

        private enum CodingKeys: String, CodingKey { case id, link, targets, lastAliasRequest }

        /// Only the id is required; any other field of an unexpected shape is ignored.
        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            id = try fields.decode(String.self, forKey: .id)
            link = try? fields.decodeIfPresent(Link.self, forKey: .link)
            targets = try? fields.decodeIfPresent(Targets.self, forKey: .targets)
            lastAliasRequest = try? fields.decodeIfPresent(AliasRequest.self, forKey: .lastAliasRequest)
        }
    }

    private struct RawTarget: Decodable {
        var id: String?
        var url: String?
        var alias: [String]
        var meta: VercelGitMeta?
        var createdAt: Double?

        private enum CodingKeys: String, CodingKey { case id, url, alias, meta, createdAt }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            id = try? fields.decodeIfPresent(String.self, forKey: .id)
            url = try? fields.decodeIfPresent(String.self, forKey: .url)
            alias = (try? fields.decodeIfPresent([String].self, forKey: .alias)) ?? []
            meta = try? fields.decodeIfPresent(VercelGitMeta.self, forKey: .meta)
            createdAt = try? fields.decodeIfPresent(Double.self, forKey: .createdAt)
        }
    }

    private struct RawAliases: Decodable {
        struct Row: Decodable {
            var alias: String?
            var deploymentId: String?
            var deployment: Deployment?
        }
        struct Deployment: Decodable {
            var id: String?
            var url: String?
        }

        var aliases: [Row]
    }

    private struct RawComments: Decodable {
        struct Scope: Decodable { var projectId: String? }
        struct Thread: Decodable {
            var branch: String?
            @DecodedDefault<DefaultFalse> var resolved: Bool
            var webUrl: String?
            var url: String?
        }

        var scope: Scope?
        var threads: [Thread]
    }
}
