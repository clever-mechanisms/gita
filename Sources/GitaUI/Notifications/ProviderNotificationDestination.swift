import Foundation
import GitaCore

/// One immutable provider fact a notification can route back to (repository, validated hosted source, exact item).
struct ProviderNotificationDestination: Codable, Sendable, Hashable {
    let schemaVersion: Int
    let repositoryPath: String
    let commonGitDirectoryPath: String
    let providerSourceID: String
    let itemID: String
    let target: ProviderTarget
    let title: String
    let state: SignalState
    let branch: String?
    let commit: String?
    let url: URL?
    let observedAt: Date
    /// What happened; nil only in older records, which carried just an outcome.
    var event: AttentionKind?
    /// Who did it (PR author or merger), when the provider reported a login.
    var actor: String?
}
