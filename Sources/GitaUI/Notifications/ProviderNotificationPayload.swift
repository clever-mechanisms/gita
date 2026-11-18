import CryptoKit
import Foundation
import GitaCore

/// The wire payload of a provider notification: keys that identify one exact item and event, and the bounded
/// JSON a notification carries. It deliberately excludes mutable lists, raw remote URLs and CLI output.
enum ProviderNotificationPayload {
    static let userInfoKey = "gitaProviderCompletionV1"
    static let byteLimit = 16 * 1_024

    static func validSource(_ source: String, provider: ProviderKind) -> Bool {
        switch provider {
        case .github:
            guard source.hasPrefix("github:") else { return false }
            let name = String(source.dropFirst(7))
            return repository(name) && name == name.lowercased()
        case .vercel:
            guard source.hasPrefix("vercel:") else { return false }
            let ids = source.dropFirst(7).split(separator: "/", omittingEmptySubsequences: false)
            return ids.count == 2 && identifier(String(ids[0])) && identifier(String(ids[1]))
                && ids[1].hasPrefix("prj_") && ids[1].count > 4
        case .orca:
            return false
        }
    }

    static func entityKey(source: String, target: ProviderTarget) -> String? {
        switch target {
        case .workflowRun(let name, let runID, let attempt):
            guard isGitHubSource(source, repository: name), runID > 0, attempt > 0, attempt <= Int(Int32.max) else {
                return nil
            }
            return components([source, "run", String(runID), "attempt", String(attempt)])
        case .deployment(let reference, let project, let scope):
            guard validSource(source, provider: .vercel), let reference = deploymentReference(reference),
                slug(project), scope.map(slug) ?? true
            else { return nil }
            // Scope/project display names may change. The source already binds
            // the immutable organization/project IDs; this is one exact deployment.
            return components([source, "deployment", reference])
        case .pullRequest(let name, let number):
            guard isGitHubSource(source, repository: name), number > 0, number <= Int(Int32.max) else { return nil }
            return components([source, "pr", String(number)])
        }
    }

    private static func isGitHubSource(_ source: String, repository name: String) -> Bool {
        validSource(source, provider: .github) && repository(name) && source == "github:" + name.lowercased()
    }

    /// One notification per exact item and event: a run attempt's outcome, a deployment, or a PR opened/merged/review
    /// request.
    static func outcomeKey(_ destination: ProviderNotificationDestination) -> String? {
        guard let identity = entityKey(source: destination.providerSourceID, target: destination.target) else {
            return nil
        }
        if let event = destination.event { return digest(components([identity, event.rawValue])) }
        guard destination.state == .success || destination.state == .failure else { return nil }
        if case .pullRequest = destination.target { return nil }
        return digest(components([identity, destination.state.rawValue]))
    }

    static func encode(_ destination: ProviderNotificationDestination) -> Data? {
        guard valid(destination), let data = try? encoder().encode(destination), data.count <= byteLimit else {
            return nil
        }
        return data
    }
    static func decode(_ data: Data) -> ProviderNotificationDestination? {
        guard data.count <= byteLimit,
            let destination = try? decoder().decode(ProviderNotificationDestination.self, from: data),
            valid(destination)
        else { return nil }
        return destination
    }
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    /// A real date that is not in the future (allowing clock skew).
    static func date(_ value: Date, now: Date = Date()) -> Bool {
        value.timeIntervalSince1970.isFinite && value.timeIntervalSince1970 >= 0
            && value <= now.addingTimeInterval(ProviderNotificationContext.skew)
    }
    /// Length-prefixed, so no two different lists join to the same string.
    private static func components(_ values: [String]) -> String { values.map { "\($0.utf8.count):\($0)" }.joined() }
}
