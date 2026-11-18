import Foundation

/// One deployment's metadata and, when its project identity is verified, its project.
public struct DeploymentDetail: Sendable {
    public var id: String
    public var projectName: String
    /// Immutable project binding from the deployment, independent of renames.
    public var projectID: String?
    public var scope: String?
    public var state: SignalState
    public var previewURL: URL?
    public var dashboardURL: URL?
    public var aliases: [URL]
    public var createdAt: Date?
    public var durationMilliseconds: Double?
    public var reason: String?
    public var commit: String?
    public var branch: String?
    public var project: DeploymentProject?
}

public struct DeploymentProject: Sendable {
    public var name: String
    public var framework: String?
}
