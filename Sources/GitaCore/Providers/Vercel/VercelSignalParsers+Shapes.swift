import Foundation

/// The selective response shapes of the signal reads.
extension VercelSignalParsers {
    /// ISO 8601 text or Unix seconds or milliseconds, as a number or as text.
    struct FlexibleDate: Decodable, Sendable {
        var date: Date?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self) {
                date = ProviderDates.unix(number)
            } else if let text = try? container.decode(String.self) {
                date = ProviderDates.iso8601(text) ?? Double(text).flatMap(ProviderDates.unix)
            }
        }
    }

    struct RawLogRecord: Decodable {
        /// Only identity: message, path, host, IP and agent are never decoded.
        struct Record: Decodable { var deploymentId: String? }
        struct Page: Decodable { @DecodedDefault<DefaultFalse> var hasMore: Bool }

        var type: String?
        var data: Record?
        var recordsReturned: Int?
        var pagination: Page?
    }

    struct RawCIList: Decodable {
        struct Run: Decodable {
            var id: String?
            var status: String?
            var branch: String?
            var commitSha: String?
            var createdAt: FlexibleDate?
        }

        var runs: [Run]
    }

    struct RawRolloutEnvelope: Decodable {
        struct Release: Decodable {
            var state: String?
            var substate: String?
            var advancementType: String?
            var canaryDeployment: Deployment?
            var activeStage: Stage?
            var nextStage: Stage?
            @DecodedDefault<DefaultEmpty<Stage>> var stages: [Stage]
            var currentCanaryPercentage: Double?
        }
        struct Deployment: Decodable, Sendable {
            var id: String?
            var url: String?
        }
        struct Stage: Decodable, Sendable {
            var index: Double?
            var targetPercentage: Double?
            @DecodedDefault<DefaultFalse> var requireApproval: Bool
        }

        var rollingRelease: Release?
    }

    /// No title, message or trigger text: status only.
    struct RawAgentRuns: Decodable {
        struct Run: Decodable, Sendable {
            var status: String?
            var state: String?
        }
        struct Summary: Decodable {
            var runs: Int?
            var failed: Int?
        }
        struct PageInfo: Decodable { var total: Int? }

        @DecodedDefault<DefaultEmpty<Run>> var runs: [Run]
        var summary: Summary?
        var pageInfo: PageInfo?
    }

    struct RawAlerts: Decodable { var groups: [RawAlertGroup] }

    struct RawAlertGroup: Decodable {
        var id: String?
        var type: String?
        var alertType: String?
        var title: String?
        var status: String?
        var url: String?
        var startedAt: FlexibleDate?
        var createdAt: FlexibleDate?
        var resolvedAt: FlexibleDate?
        var endedAt: FlexibleDate?
    }

    struct RawHealth: Decodable {
        struct Page: Decodable { var url: String? }
        struct Status: Decodable {
            var indicator: String?
            var description: String?
        }

        var page: Page?
        var status: Status?
        @DecodedDefault<DefaultEmpty<RawIncident>> var incidents: [RawIncident]
    }

    struct RawIncident: Decodable, Sendable {
        struct Component: Decodable, Sendable { var name: String? }

        var id: String?
        var name: String?
        var status: String?
        var url: String?
        var resolvedAt: String?
        @DecodedDefault<DefaultEmpty<Component>> var components: [Component]
    }
}
