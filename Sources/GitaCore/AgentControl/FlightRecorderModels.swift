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

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.refName == rhs.refName
            && lhs.sequence == rhs.sequence
            && lhs.createdAt == rhs.createdAt
            && lhs.trigger == rhs.trigger
            && lhs.tool == rhs.tool
            && lhs.sessionID == rhs.sessionID
            && lhs.label == rhs.label
            && lhs.changedFileCount == rhs.changedFileCount
            && lhs.parentOID == rhs.parentOID
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(refName)
        hasher.combine(sequence)
        hasher.combine(createdAt)
        hasher.combine(trigger)
        hasher.combine(tool)
        hasher.combine(sessionID)
        hasher.combine(label)
        hasher.combine(changedFileCount)
        hasher.combine(parentOID)
    }
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
