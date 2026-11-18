import Foundation

public enum ProviderItemKind: String, Sendable, Hashable {
    case pullRequest, workflowRun, check, deployment, agent, other
}

/// Command identity comes from validated provider data, never a display title.
public enum ProviderTarget: Sendable, Hashable, Codable {
    case pullRequest(repository: String, number: Int)
    case workflowRun(repository: String, runID: Int64, attempt: Int)
    case deployment(reference: String, projectName: String, scope: String?)
}

extension ProviderTarget {
    /// The `sourceID` of the GitHub repository a pull request or workflow run belongs to (the key its account is
    /// stored under); nil for a deployment or an invalid name.
    public var githubSourceID: String? {
        switch self {
        case .pullRequest(let repository, _), .workflowRun(let repository, _, _):
            GitHubRepository(nameWithOwner: repository)?.sourceID
        case .deployment: nil
        }
    }
}
