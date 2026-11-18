import Foundation

/// Production errors, Vercel CI, rolling releases, Agent Runs, alerts and Vercel's own status.
/// Display metadata only: counts, states, IDs and dates.
public struct VercelSignals: Sendable, Hashable {
    public enum Part: String, Sendable, CaseIterable { case errors, ci, rollout, agentRuns, alerts, platform }

    /// Server errors and logged errors of the live production deployment in the last hour.
    public struct Errors: Sendable, Hashable {
        public var deploymentID: String
        public var serverErrors: Int?
        public var loggedErrors: Int?
        /// The count reached the read limit: there are at least this many.
        public var serverCapped: Bool
        public var loggedCapped: Bool

        public init(
            deploymentID: String, serverErrors: Int? = nil, loggedErrors: Int? = nil, serverCapped: Bool = false,
            loggedCapped: Bool = false
        ) {
            self.deploymentID = deploymentID
            self.serverErrors = serverErrors
            self.loggedErrors = loggedErrors
            self.serverCapped = serverCapped
            self.loggedCapped = loggedCapped
        }

        public var hasErrors: Bool { (serverErrors ?? 0) > 0 || (loggedErrors ?? 0) > 0 }
    }

    public struct CIRun: Sendable, Hashable {
        public var id: String
        public var status: CIStatus
        public var branch: String?
        public var commit: String
        public var createdAt: Date?

        public var state: SignalState { status.state }

        public init(id: String, status: CIStatus, branch: String?, commit: String, createdAt: Date?) {
            self.id = id
            self.status = status
            self.branch = branch
            self.commit = commit
            self.createdAt = createdAt
        }
    }

    public struct Rollout: Sendable, Hashable {
        /// Vercel's rollout states; the raw value is Vercel's word. Any other word is a response Gitā cannot read.
        public enum State: String, Sendable, Hashable, CaseIterable {
            case active = "ACTIVE"
            case complete = "COMPLETE"
            case aborted = "ABORTED"
        }

        /// Whether the rollout is what the last read returned, or one kept from before a read that failed. A stale
        /// rollout is still shown, but no step is offered on it: its stage may have moved or the rollout ended.
        public enum Freshness: Sendable, Hashable {
            case current
            case stale
        }

        public var state: State
        /// Vercel's `PAUSED` substate of an active rollout (a manual-approval release pauses at each stage until it is
        /// approved); never set for an ended one.
        public var isPaused: Bool
        public var canaryDeploymentID: String?
        public var canaryHost: String?
        public var percentage: Int?
        public var stageIndex: Int?
        public var stageCount: Int
        public var nextStageNeedsApproval: Bool
        public var freshness = Freshness.current

        public init(
            state: State, isPaused: Bool = false, canaryDeploymentID: String? = nil, canaryHost: String? = nil,
            percentage: Int? = nil, stageIndex: Int? = nil, stageCount: Int = 0, nextStageNeedsApproval: Bool = false
        ) {
            self.state = state
            self.isPaused = isPaused
            self.canaryDeploymentID = canaryDeploymentID
            self.canaryHost = canaryHost
            self.percentage = percentage
            self.stageIndex = stageIndex
            self.stageCount = stageCount
            self.nextStageNeedsApproval = nextStageNeedsApproval
        }

        public var isActive: Bool { state == .active && canaryDeploymentID != nil }
    }

    public struct AgentRuns: Sendable, Hashable {
        public var total: Int
        public var failed: Int

        public init(total: Int, failed: Int = 0) {
            self.total = total
            self.failed = failed
        }
    }

    public struct Alert: Sendable, Hashable {
        public var id: String
        /// Vercel's alert type, such as `error_anomaly`.
        public var type: String?
        public var title: String?
        public var startedAt: Date?
        public var resolvedAt: Date?
        public var url: URL?

        public init(
            id: String, type: String? = nil, title: String? = nil, startedAt: Date? = nil, resolvedAt: Date? = nil,
            url: URL? = nil
        ) {
            self.id = id
            self.type = type
            self.title = title
            self.startedAt = startedAt
            self.resolvedAt = resolvedAt
            self.url = url
        }

        public var isActive: Bool { resolvedAt == nil }
    }

    public struct Platform: Sendable, Hashable {
        public struct Incident: Sendable, Hashable {
            public var name: String
            public var components: [String]
            public var url: URL?

            public init(name: String, components: [String] = [], url: URL? = nil) {
                self.name = name
                self.components = components
                self.url = url
            }
        }

        /// Statuspage indicator: none, minor, major, critical or maintenance.
        public var indicator: String
        public var summary: String
        public var incidents: [Incident]
        public var pageURL: URL?

        public init(indicator: String, summary: String, incidents: [Incident] = [], pageURL: URL? = nil) {
            self.indicator = indicator
            self.summary = summary
            self.incidents = incidents
            self.pageURL = pageURL
        }

        public var isDegraded: Bool { (indicator != "none" && indicator != "maintenance") || !incidents.isEmpty }
    }

    /// When a part was last read (successfully or not), with its key and whether it came back empty.
    public struct Read: Sendable, Hashable {
        public var at: Date
        public var key: String
        public var outcome: Outcome

        public init(at: Date, key: String, outcome: Outcome) {
            self.at = at
            self.key = key
            self.outcome = outcome
        }
    }

    public enum Outcome: String, Sendable, Hashable { case value, empty, failed }

    public var errors: Errors?
    public var ci: [CIRun]
    public var rollout: Rollout?
    public var agentRuns: AgentRuns?
    public var alerts: [Alert]
    public var platform: Platform?
    public var reads: [Part: Read]

    public init(
        errors: Errors? = nil, ci: [CIRun] = [], rollout: Rollout? = nil, agentRuns: AgentRuns? = nil,
        alerts: [Alert] = [], platform: Platform? = nil, reads: [Part: Read] = [:]
    ) {
        self.errors = errors
        self.ci = ci
        self.rollout = rollout
        self.agentRuns = agentRuns
        self.alerts = alerts
        self.platform = platform
        self.reads = reads
    }

    public var activeAlerts: [Alert] { alerts.filter(\.isActive) }

    /// Vercel CI runs as checks of their commits: the newest attempt of each run.
    func ciItems() -> [ProviderItem] {
        var seen = Set<String>()
        return ci.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }.compactMap { run in
            guard seen.insert(run.id).inserted else { return nil }
            return ProviderItem(
                id: "vercel-ci:\(run.id)", provider: .vercel, category: "Vercel CI", title: "Vercel CI",
                state: run.state, detail: run.status.rawValue, commit: run.commit, branch: run.branch,
                date: run.createdAt,
                kind: .workflowRun)
        }
    }
}
