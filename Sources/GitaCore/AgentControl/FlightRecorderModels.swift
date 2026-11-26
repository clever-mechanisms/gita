import Foundation

public enum FlightSnapshotTrigger: String, Codable, Sendable, Hashable {
    case userPromptSubmit, agentStop, codexTurnComplete, manual
}

public struct FlightSnapshot: Identifiable, Sendable, Hashable {
    public let id: String
    public let refName: String
    public let sequence: Int
    public let createdAt: Date
    public let trigger: FlightSnapshotTrigger
    public let tool: AgentTool?
    public let sessionID: String?
    public let label: String
    public let changedFileCount: Int
    public let parentOID: String?
}

public struct FlightDiffResult: Sendable, Equatable {
    public let fromLabel, toLabel, diffText: String
    public let files: [String]
    public let isTruncated: Bool
}

public enum FlightWriteKind: String, Sendable, Equatable {
    case enabling, disabling, capturing, clearing
}

public enum FlightRecorderState: Sendable, Equatable {
    case disabled, idle, loading
    case writing(FlightWriteKind)
    case loaded([FlightSnapshot])
    case empty
    case restoring(snapshotID: String)
    case failed(String)
}
