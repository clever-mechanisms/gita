import Foundation

/// One agent process as seen by a scan. CPU is cumulative (monotonic) and includes recently started descendants.
public struct AgentProcessSample: Sendable, Hashable {
    public var tool: AgentTool
    public var pid: Int32
    /// The nearest ancestor that is an agent of the same tool in another folder (a delegated run); nil for
    /// top-level sessions.
    public var parentAgentPID: Int32?
    public var workingDirectory: String
    public var startedAt: Date
    /// Seconds of CPU this session (process plus descendants started in the last 15 minutes) used since it was
    /// first seen.
    public var cpuSeconds: Double
    /// Services count only inside a Git checkout (see `AgentProcessIdentity.isService`); no terminal also means
    /// service.
    public var isService: Bool
}
