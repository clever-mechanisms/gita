import Foundation
import GitaCore

/// The text lines of a provider detail card, computed from the loaded detail and the list item's summary.
@MainActor
enum ProviderDetailFacts {
    private static let separator = " · "
    /// Failing and running checks listed by name under the tally.
    static let listedCheckLimit = 6

    // MARK: Pull request

    /// "octocat · 2d ago": who opened it and when; nil when neither is known.
    static func openedBy(_ value: PullRequestDetail, summary: PullRequestSummary?) -> String? {
        joined([value.author ?? summary?.author, summary?.createdAt.map { DeckFormat.relative($0) }])
    }
    static func mergedBy(_ summary: PullRequestSummary?) -> String? {
        guard let mergedBy = summary?.mergedBy else { return nil }
        return joined([mergedBy, summary?.mergedAt.map { DeckFormat.relative($0) }])
    }
    /// "feature → main".
    static func branches(_ value: PullRequestDetail) -> String? {
        guard let head = value.headBranch else { return nil }
        return value.baseBranch.map { "\(head) → \($0)" } ?? head
    }
    /// Each review, then the requested reviewers; the review decision alone when there is neither.
    static func reviewLines(_ value: PullRequestDetail) -> [String] {
        var lines = value.reviews.items.map {
            "\($0.status.localizedTitle) · \($0.author ?? String(localized: "Reviewer unavailable"))"
        }
        let requested = value.requestedReviewers.items.map(\.name)
        if !requested.isEmpty {
            lines.append(String(localized: "Requested · \(requested.joined(separator: ", "))"))
        }
        if lines.isEmpty, let decision = value.reviewDecision { lines.append(decision.localizedTitle) }
        return lines
    }
    static func hasChecks(_ page: ProviderPage<ProviderCheck>) -> Bool { !page.items.isEmpty || page.total ?? 0 > 0 }
    /// Mergeability is only worth saying while the pull request is open.
    static func merge(_ value: PullRequestDetail) -> String? {
        guard let mergeability = value.mergeability, value.lifecycle == .open else { return nil }
        return mergeability.localizedTitle
    }

    // MARK: Checks

    struct CheckTally {
        var headline: String
        var hasFailures: Bool
        /// The failed checks, then the running ones, at most `listedCheckLimit`.
        var listed: [ProviderCheck]
    }
    static func tally(_ page: ProviderPage<ProviderCheck>) -> CheckTally {
        let failed = page.items.filter { $0.state == .failure }
        let running = page.items.filter { $0.state == .running || $0.state == .pending }
        let passed = page.items.filter { $0.state == .success }.count
        var parts: [String] = []
        if passed > 0 { parts.append(String(localized: "\(passed) passed")) }
        if !failed.isEmpty { parts.append(String(localized: "\(failed.count) failed")) }
        if !running.isEmpty { parts.append(String(localized: "\(running.count) running")) }
        if let total = page.total, total > page.items.count { parts.append(String(localized: "\(total) total")) }
        return CheckTally(
            headline: parts.joined(separator: separator), hasFailures: !failed.isEmpty,
            listed: Array((failed + running).prefix(listedCheckLimit)))
    }
    static func checkName(_ check: ProviderCheck) -> String {
        [check.workflow, check.name].compactMap { $0 }.joined(separator: separator)
    }

    // MARK: Workflow run

    static func workflow(_ value: WorkflowRunDetail) -> String? { joined([value.workflow, value.event]) }
    static func noJobsText(_ value: WorkflowRunDetail) -> String {
        value.jobs.total == 0 ? String(localized: "No jobs") : String(localized: "Jobs unavailable")
    }
    static func elapsed(_ started: Date?, _ completed: Date?) -> String {
        guard let started, let completed else { return "" }
        return DeckFormat.duration(completed.timeIntervalSince(started))
    }

    // MARK: Deployment

    /// The preview URL and the aliases, safe web URLs only, each once.
    static func addresses(_ value: DeploymentDetail) -> [URL] {
        var seen = Set<URL>()
        return ([value.previewURL].compactMap { $0 } + value.aliases).compactMap(Deck.safeWebURL).filter {
            seen.insert($0).inserted
        }
    }
    /// "Built in 42s · 3h ago".
    static func build(_ value: DeploymentDetail) -> String? {
        let duration = value.durationMilliseconds.flatMap {
            $0.isFinite && $0 >= 0 ? DeckFormat.duration($0 / 1_000) : nil
        }
        return joined([
            duration.map { String(localized: "Built in \($0)") }, value.createdAt.map { DeckFormat.relative($0) },
        ])
    }
    /// "main · 1a2b3c4".
    static func source(_ value: DeploymentDetail) -> String? {
        joined([value.branch, value.commit.map { String($0.prefix(7)) }])
    }
    static func failureReason(_ value: DeploymentDetail) -> String? { value.state == .failure ? value.reason : nil }
    static func project(_ value: DeploymentDetail) -> String {
        [value.project?.name ?? value.projectName, value.project?.framework, value.scope].compactMap { $0 }.joined(
            separator: separator)
    }

    // MARK: Failure

    static func failure(_ report: ProviderDetailReport) -> String {
        [report.localizedStatus, report.diagnostic].compactMap { $0 }.filter { !$0.isEmpty }.joined(
            separator: separator)
    }

    /// The present parts joined with " · "; nil when none is present.
    private static func joined(_ parts: [String?]) -> String? {
        let present = parts.compactMap { $0 }
        return present.isEmpty ? nil : present.joined(separator: separator)
    }
}
