import Foundation

/// `vercel list --json`, one deployment's metadata and its project, each bound to the identity that was asked for.
enum VercelDeploymentParser {
    static let listSize = 30
    private static let aliasLimit = 100
    private static let reasonLimit = 500

    static func state(_ readyState: String?) -> SignalState {
        switch readyState?.uppercased() {
        case "READY": .success
        case "ERROR", "BLOCKED": .failure
        case "BUILDING", "INITIALIZING": .running
        case "QUEUED": .pending
        case "CANCELED", "CANCELLED": .cancelled
        default: .neutral
        }
    }

    /// The raw status token of a ready state; `fallback` names states Vercel added later.
    static func label(_ readyState: String?, fallback: String) -> String {
        switch readyState?.uppercased() {
        case "READY": "Ready"
        case "BLOCKED": "Blocked"
        default: state(readyState).statusToken(fallback: fallback)
        }
    }

    // MARK: List

    private struct List: Decodable {
        var deployments: [VercelDeploymentDTO]
        var contextName: String?
    }

    static func items(_ data: Data) throws -> [ProviderItem] {
        let list = try JSONDecoder().decode(List.self, from: data)
        return list.deployments.prefix(listSize).compactMap { item($0, scope: list.contextName) }
    }

    private static func item(_ row: VercelDeploymentDTO, scope: String?) -> ProviderItem? {
        guard let address = ProviderValidation.nonempty(row.url),
            let url = ProviderValidation.safeWebURL(address.hasPrefix("https://") ? address : "https://" + address)
        else { return nil }
        let readyState = row.readyState ?? row.state
        let environment = row.environment
        let environmentName = environment.name ?? String(localized: "Environment unknown")
        let status = ProviderText.status(label(readyState, fallback: "Status unknown"))
        let reference = row.uid ?? row.id ?? address
        let created = ProviderDates.milliseconds(row.createdAt ?? row.created)
        return ProviderItem(
            id: "vercel:\(reference)", provider: .vercel, category: String(localized: "Deployment"),
            title: row.name ?? environmentName, state: state(readyState),
            detail: String(localized: "\(environmentName) · \(status)"), commit: row.meta?.commit,
            branch: row.meta?.branch, url: url, date: created, kind: .deployment,
            target: VercelIdentifiers.deploymentTarget(reference: reference, projectName: row.name, scope: scope),
            deployment: DeploymentSummary(environment: environment), startedAt: created)
    }

    // MARK: Detail

    private struct Detail: Decodable {
        struct Duration: Decodable { var timeToReady: Double? }
        struct Team: Decodable {
            var id: String?
            var slug: String?
        }
        struct GitSource: Decodable {
            var sha: String?
            var ref: String?
        }
        struct ProjectIdentity: Decodable { var id: String? }

        var readyStateReason: String?
        var duration: Duration?
        @DecodedDefault<DefaultEmpty<String>> var alias: [String]
        var team: Team?
        var inspectorUrl: String?
        var gitSource: GitSource?
        var errorMessage: String?
        var projectId: String?
        var project: ProjectIdentity?
    }

    static func detail(_ data: Data, reference: String, projectName: String, scope: String?) throws -> DeploymentDetail
    {
        let row = try JSONDecoder().decode(VercelDeploymentDTO.self, from: data)
        let extra = try JSONDecoder().decode(Detail.self, from: data)
        guard let requested = VercelIdentifiers.deploymentReference(reference), let id = row.id,
            VercelIdentifiers.isDeploymentID(id), row.name == projectName, let readyState = row.readyState,
            let address = row.url.flatMap(VercelIdentifiers.deploymentReference),
            requested == id || requested == address,
            matchesScope(scope, team: extra.team)
        else { throw ProviderResponseError.shape }
        return DeploymentDetail(
            id: id, projectName: projectName, projectID: projectID(extra), scope: scope ?? extra.team?.slug,
            state: state(readyState), previewURL: ProviderValidation.httpsURL(host: address),
            dashboardURL: ProviderValidation.safeWebURL(extra.inspectorUrl), aliases: aliases(extra.alias),
            createdAt: ProviderDates.milliseconds(row.createdAt),
            durationMilliseconds: extra.duration?.timeToReady.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil },
            reason: (ProviderValidation.nonempty(extra.readyStateReason)
                ?? ProviderValidation.nonempty(extra.errorMessage))
                .map { String($0.prefix(reasonLimit)) },
            commit: ProviderValidation.nonempty(extra.gitSource?.sha) ?? row.meta?.commit,
            branch: ProviderValidation.nonempty(extra.gitSource?.ref) ?? row.meta?.branch)
    }

    private static func matchesScope(_ scope: String?, team: Detail.Team?) -> Bool {
        guard let scope, let slug = team?.slug else { return true }
        return scope == slug || scope == team?.id
    }

    /// Project names can be renamed and reused. Only a consistent immutable id from this deployment may bind a later
    /// project metadata response.
    private static func projectID(_ extra: Detail) -> String? {
        guard let id = extra.projectId, VercelIdentifiers.isProjectID(id), extra.project?.id.map({ $0 == id }) ?? true
        else { return nil }
        return id
    }

    private static func aliases(_ values: [String]) -> [URL] {
        values.prefix(aliasLimit).compactMap { address in
            guard let host = VercelIdentifiers.deploymentReference(address), !host.hasPrefix("dpl_") else { return nil }
            return ProviderValidation.httpsURL(host: host)
        }
    }

    // MARK: Project

    private struct Project: Decodable {
        struct Owner: Decodable { var slug: String? }

        var id: String
        var name: String
        var owner: Owner?
        var framework: String?
    }

    static func project(_ data: Data, projectID: String, scope: String?) throws -> DeploymentProject {
        let row = try JSONDecoder().decode(Project.self, from: data)
        guard VercelIdentifiers.isProjectID(projectID), row.id == projectID, ProviderValidation.isSlug(row.name),
            scope == nil || row.owner?.slug == nil || scope == row.owner?.slug
        else { throw ProviderResponseError.shape }
        return DeploymentProject(name: row.name, framework: row.framework)
    }
}
