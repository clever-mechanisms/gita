import Foundation

/// One attempt of a workflow run and its first page of jobs.
public struct WorkflowRunDetail: Sendable {
    public var runID: Int64
    public var number: Int
    public var attempt: Int
    public var title: String
    public var workflow: String?
    public var event: String?
    public var state: SignalState
    public var commit: String?
    public var branch: String?
    public var url: URL?
    public var jobs: ProviderPage<WorkflowJob>
}

public struct WorkflowJob: Identifiable, Sendable {
    public var id: Int64
    public var name: String
    public var state: SignalState
    public var url: URL?
    public var startedAt: Date?
    public var completedAt: Date?
    public var steps: [WorkflowStep]
    public var stepsTruncated: Bool
}

public struct WorkflowStep: Identifiable, Sendable {
    public var number: Int
    public var id: Int { number }
    public var name: String
    public var state: SignalState
}
