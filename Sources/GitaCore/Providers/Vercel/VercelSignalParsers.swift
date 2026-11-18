import Foundation

/// The signal reads, each decoding only counts, states, ids and dates. A nil result means the feature is not in use.
enum VercelSignalParsers {
    struct Count: Sendable {
        var count: Int
        var capped: Bool
    }

    private static let countLimit = 10_000
    private static let ciLimit = 100
    private static let alertLimit = 100
    private static let incidentLimit = 20
    private static let componentLimit = 6

    /// `vercel logs --json`: JSON Lines of `{type, data}` records ending with a summary. Only records of `kind` for the
    /// deployment count; the summary's `hasMore` marks a capped count. Without a summary it is no count at all.
    static func count(_ data: Data, kind: String, deploymentID: String) throws -> Count {
        var count = 0
        var capped = false
        var sawSummary = false
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            guard let record = try? JSONDecoder().decode(RawLogRecord.self, from: Data(line)) else { continue }
            if record.type == "summary" {
                sawSummary = true
                capped = record.pagination?.hasMore == true
                if let returned = record.recordsReturned, returned >= 0 {
                    count = max(count, min(returned, countLimit))
                }
            } else if !sawSummary, record.type == kind, record.data?.deploymentId.map({ $0 == deploymentID }) ?? true {
                count += 1
            }
        }
        guard sawSummary else { throw ProviderResponseError.shape }
        return Count(count: count, capped: capped)
    }

    static func ciRuns(_ data: Data) throws -> [VercelSignals.CIRun] {
        let runs = try JSONDecoder().decode(RawCIList.self, from: data).runs.prefix(ciLimit).compactMap { run in
            guard let id = run.id, ProviderValidation.isSlug(id), let commit = run.commitSha?.lowercased(),
                GitParsers.isObjectID(commit)
            else { return nil as VercelSignals.CIRun? }
            return VercelSignals.CIRun(
                id: id, status: VercelSignals.CIStatus(vercel: run.status),
                branch: ProviderValidation.bounded(run.branch), commit: commit,
                createdAt: run.createdAt?.date)
        }
        return Array(runs)
    }

    static func rollout(_ data: Data) throws -> VercelSignals.Rollout? {
        guard let release = try JSONDecoder().decode(RawRolloutEnvelope.self, from: data).rollingRelease else {
            return nil
        }
        guard let state = release.state.flatMap({ VercelSignals.Rollout.State(rawValue: $0.uppercased()) }) else {
            throw ProviderResponseError.shape
        }
        let active = release.activeStage
        let percentage = release.currentCanaryPercentage ?? active?.targetPercentage
        return VercelSignals.Rollout(
            state: state, isPaused: state == .active && release.substate?.uppercased() == "PAUSED",
            canaryDeploymentID: VercelIdentifiers.deploymentID(release.canaryDeployment?.id),
            canaryHost: release.canaryDeployment?.url.flatMap(VercelIdentifiers.deploymentReference),
            percentage: percentage.flatMap { $0.isFinite ? Int(max(0, min(100, $0)).rounded()) : nil },
            stageIndex: active?.index.flatMap { $0.isFinite && $0 >= 0 ? Int($0) : nil },
            stageCount: min(release.stages.count, 100),
            nextStageNeedsApproval: release.nextStage?.requireApproval == true
                || (release.advancementType == "manual-approval" && release.nextStage != nil))
    }

    private static let failedRunStates: Set<String> = ["failed", "error", "errored"]

    static func agentRuns(_ data: Data) throws -> VercelSignals.AgentRuns? {
        let raw = try JSONDecoder().decode(RawAgentRuns.self, from: data)
        let total = raw.summary?.runs ?? raw.pageInfo?.total ?? raw.runs.count
        guard total > 0 || !raw.runs.isEmpty else { return nil }
        let failed = raw.runs.filter { failedRunStates.contains(($0.status ?? $0.state)?.lowercased() ?? "") }.count
        return VercelSignals.AgentRuns(total: max(total, raw.runs.count), failed: raw.summary?.failed ?? failed)
    }

    private static let closedAlertStates: Set<String> = ["resolved", "closed"]
    private static let maximumAlertID = 128
    private static let maximumAlertType = 64
    private static let maximumTitle = 160

    static func alerts(_ data: Data) throws -> [VercelSignals.Alert] {
        Array(try JSONDecoder().decode(RawAlerts.self, from: data).groups.prefix(alertLimit).compactMap(alert))
    }

    private static func alert(_ group: RawAlertGroup) -> VercelSignals.Alert? {
        guard let id = group.id, id.count <= maximumAlertID, ProviderValidation.isSlug(id) else { return nil }
        let url = ProviderValidation.safeWebURL(group.url).flatMap { $0.host?.lowercased() == "vercel.com" ? $0 : nil }
        // A closed group without an end time still counts as resolved.
        let closed = closedAlertStates.contains(group.status?.lowercased() ?? "")
        return VercelSignals.Alert(
            id: id, type: ProviderValidation.bounded(group.type ?? group.alertType, limit: maximumAlertType),
            title: ProviderValidation.nonempty(group.title).map { String($0.prefix(maximumTitle)) },
            startedAt: (group.startedAt ?? group.createdAt)?.date,
            resolvedAt: (group.resolvedAt ?? group.endedAt)?.date ?? (closed ? Date(timeIntervalSince1970: 0) : nil),
            url: url)
    }

    private static let maximumIndicator = 32
    private static let maximumSummary = 120
    private static let maximumComponent = 60
    private static let statusPage = "https://www.vercel-status.com"

    static func platform(_ data: Data) throws -> VercelSignals.Platform? {
        let raw = try JSONDecoder().decode(RawHealth.self, from: data)
        guard let indicator = raw.status?.indicator?.lowercased(), indicator.count <= maximumIndicator else {
            throw ProviderResponseError.shape
        }
        return VercelSignals.Platform(
            indicator: indicator, summary: String((raw.status?.description ?? "").prefix(maximumSummary)),
            incidents: Array(raw.incidents.prefix(incidentLimit).compactMap(incident)),
            pageURL: statusPageURL(raw.page?.url) ?? URL(string: statusPage))
    }

    private static func incident(_ incident: RawIncident) -> VercelSignals.Platform.Incident? {
        guard incident.resolvedAt == nil, incident.status?.lowercased() != "resolved",
            let id = incident.id, ProviderValidation.isSlug(id), let name = ProviderValidation.nonempty(incident.name)
        else { return nil }
        return VercelSignals.Platform.Incident(
            name: String(name.prefix(maximumTitle)),
            components: incident.components.prefix(componentLimit).compactMap {
                $0.name.map { String($0.prefix(maximumComponent)) }
            }, url: statusPageURL(incident.url))
    }

    private static func statusPageURL(_ text: String?) -> URL? {
        ProviderValidation.safeWebURL(text).flatMap {
            $0.host?.lowercased().hasSuffix("vercel-status.com") == true ? $0 : nil
        }
    }
}
