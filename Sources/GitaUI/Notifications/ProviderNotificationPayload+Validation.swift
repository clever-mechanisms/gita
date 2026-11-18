import Foundation
import GitaCore

/// Strict validation of a destination before it is shown, stored or acted on.
extension ProviderNotificationPayload {
    static func valid(_ destination: ProviderNotificationDestination) -> Bool {
        guard destination.schemaVersion == 1, outcomeKey(destination) != nil,
            path(destination.repositoryPath), path(destination.commonGitDirectoryPath),
            text(destination.title, limit: 512), text(destination.itemID, limit: 1_024),
            destination.branch.map({ text($0, limit: 1_024) }) ?? true,
            destination.commit.map(commit) ?? true,
            destination.actor.map({ text($0, limit: 64) }) ?? true,
            date(destination.observedAt)
        else { return false }
        if let url = destination.url, !webURL(url) { return false }
        switch destination.target {
        case .workflowRun(let repository, let runID, let attempt):
            return validRun(destination, repository: repository, runID: runID, attempt: attempt)
        case .deployment(let reference, _, _):
            return validDeployment(destination, reference: reference)
        case .pullRequest(let repository, let number):
            return validPullRequest(destination, repository: repository, number: number)
        }
    }

    private static func validRun(
        _ destination: ProviderNotificationDestination, repository: String, runID: Int64, attempt: Int
    ) -> Bool {
        guard destination.itemID == "github:run:\(runID)" else { return false }
        guard let url = destination.url else { return true }
        let paths = [
            "/\(repository)/actions/runs/\(runID)", "/\(repository)/actions/runs/\(runID)/attempts/\(attempt)",
        ]
        return isGitHub(url) && paths.contains { $0.lowercased() == url.path.lowercased() }
    }

    private static func validDeployment(_ destination: ProviderNotificationDestination, reference: String) -> Bool {
        guard destination.itemID.hasPrefix("vercel:"),
            deploymentReference(String(destination.itemID.dropFirst(7))) == deploymentReference(reference)
        else { return false }
        guard let url = destination.url, !reference.hasPrefix("dpl_") else { return true }
        return deploymentReference(url.absoluteString) == deploymentReference(reference)
    }

    private static func validPullRequest(
        _ destination: ProviderNotificationDestination, repository: String, number: Int
    ) -> Bool {
        guard destination.itemID == "github:pr:\(number)", destination.event.map({ !$0.isAgent }) ?? false else {
            return false
        }
        guard let url = destination.url else { return true }
        return isGitHub(url) && url.path.lowercased() == "/\(repository)/pull/\(number)".lowercased()
    }

    private static func isGitHub(_ url: URL) -> Bool { url.host?.lowercased() == "github.com" }

    /// A full SHA-1 or SHA-256 commit in hexadecimal.
    private static func commit(_ value: String) -> Bool {
        [40, 64].contains(value.utf8.count) && value.unicodeScalars.allSatisfy(\.properties.isASCIIHexDigit)
    }

    private static func path(_ value: String) -> Bool {
        text(value, limit: 4_096) && value.hasPrefix("/")
            && URL(fileURLWithPath: value).standardizedFileURL.path.utf8.elementsEqual(value.utf8)
    }
    private static func text(_ value: String, limit: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= limit
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
    static func identifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy(identifierByte)
    }
    /// ASCII letters, digits, `_` and `-`.
    private static func identifierByte(_ value: UInt8) -> Bool {
        let scalar = Unicode.Scalar(value)
        return scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar))
            || value == UInt8(ascii: "_") || value == UInt8(ascii: "-")
    }
    static func slug(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 100 && !value.hasPrefix("-") && value != "." && value != ".."
            && value.utf8.allSatisfy { identifierByte($0) || $0 == UInt8(ascii: ".") }
    }
    static func repository(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return value.utf8.count <= 201 && parts.count == 2 && parts.allSatisfy { slug(String($0)) }
    }
    private static func webURL(_ url: URL) -> Bool {
        url.absoluteString.utf8.count <= 2_048 && url.scheme?.lowercased() == "https" && url.host?.isEmpty == false
            && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil && url.port == nil
    }
    /// A `dpl_` id as is, or a deployment's lower-case host name.
    static func deploymentReference(_ value: String) -> String? {
        if value.hasPrefix("dpl_"), value.count > 4, slug(value) { return value }
        guard let url = URL(string: value.hasPrefix("https://") ? value : "https://" + value), webURL(url),
            url.path.isEmpty || url.path == "/", let host = url.host?.lowercased(), host.contains("."),
            host.utf8.count <= 253, host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy(hostLabel)
        else { return nil }
        return host
    }
    private static func hostLabel(_ label: Substring) -> Bool {
        !label.isEmpty && label.utf8.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
            && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
    }
}
