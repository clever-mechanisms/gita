import Foundation

/// One deployment as `vercel list --json` and the deployment endpoints return it (selected fields only; no
/// environment, build resources or claims).
struct VercelDeploymentDTO: Decodable, Sendable {
    struct CustomEnvironment: Decodable, Sendable { var slug: String? }

    var uid: String?
    var id: String?
    var name: String?
    var url: String?
    var state: String?
    var readyState: String?
    /// An explicit `null` means preview; a missing key means unknown.
    var target: String?
    var customEnvironment: CustomEnvironment?
    var createdAt: Double?
    var created: Double?
    var meta: VercelGitMeta?

    /// A custom environment's slug, else the target.
    var environmentName: String? {
        ProviderValidation.nonempty(customEnvironment?.slug) ?? ProviderValidation.nonempty(target)
    }

    var environment: DeploymentSummary.Environment {
        if let custom = ProviderValidation.nonempty(customEnvironment?.slug) { return .custom(custom) }
        guard let target = ProviderValidation.nonempty(target) else { return .unknown }
        switch target.lowercased() {
        case "production": return .production
        case "preview": return .preview
        default: return .custom(target)
        }
    }
}

extension VercelDeploymentDTO {
    private enum CodingKeys: String, CodingKey {
        case uid, id, name, url, state, readyState, target, customEnvironment, createdAt, created, meta
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uid = try container.decodeIfPresent(String.self, forKey: .uid)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        state = try container.decodeIfPresent(String.self, forKey: .state)
        readyState = try container.decodeIfPresent(String.self, forKey: .readyState)
        target = try Self.decodeTarget(container)
        customEnvironment = try container.decodeIfPresent(CustomEnvironment.self, forKey: .customEnvironment)
        createdAt = try container.decodeIfPresent(Double.self, forKey: .createdAt)
        created = try container.decodeIfPresent(Double.self, forKey: .created)
        meta = try container.decodeIfPresent(VercelGitMeta.self, forKey: .meta)
    }

    /// `decodeIfPresent` treats `null` like a missing key, so the explicit `null` (preview) is checked first.
    private static func decodeTarget(_ container: KeyedDecodingContainer<CodingKeys>) throws -> String? {
        guard container.contains(.target) else { return nil }
        if try container.decodeNil(forKey: .target) { return "preview" }
        return try container.decode(String.self, forKey: .target)
    }
}
