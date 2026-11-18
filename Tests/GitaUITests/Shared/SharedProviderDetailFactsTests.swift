import Foundation
import Testing

@testable import GitaCore
@testable import GitaUI

@MainActor
@Suite struct SharedProviderDetailFactsTests {
    typealias Facts = ProviderDetailFacts

    @Test func pullRequestLinesJoinWhatIsKnown() throws {
        let summary = try #require(SharedFixtures.pullRequestItem(mergedBy: "hubot").pullRequest)
        let detail = SharedFixtures.pullRequestDetail()
        #expect(try #require(Facts.openedBy(detail, summary: summary)).hasPrefix("octocat · "))
        let anonymous = SharedFixtures.pullRequestDetail { $0.author = nil }
        #expect(Facts.openedBy(anonymous, summary: nil) == nil)
        #expect(try #require(Facts.mergedBy(summary)).hasPrefix("hubot · "))
        #expect(Facts.mergedBy(nil) == nil)
        #expect(Facts.branches(detail) == "feature → main")
        #expect(Facts.branches(SharedFixtures.pullRequestDetail { $0.baseBranch = nil }) == "feature")
        #expect(Facts.branches(SharedFixtures.pullRequestDetail { $0.headBranch = nil }) == nil)
        #expect(Facts.merge(detail) == "Mergeable")
        #expect(Facts.merge(SharedFixtures.pullRequestDetail { $0.lifecycle = .merged }) == nil)
        #expect(Facts.merge(SharedFixtures.pullRequestDetail { $0.mergeability = nil }) == nil)
    }

    @Test func reviewLinesListReviewsThenRequestedReviewers() {
        let reviews = [
            ProviderReview(id: "1", author: "ada", status: .approved),
            ProviderReview(id: "2", author: nil, status: .commented),
        ]
        let lines = Facts.reviewLines(
            SharedFixtures.pullRequestDetail(reviews: reviews, requested: ["grace", "linus"]))
        #expect(lines.count == 3)
        #expect(lines[0].hasSuffix(" · ada"))
        #expect(lines[1].hasSuffix(String(localized: "Reviewer unavailable")))
        #expect(lines[2].contains("grace, linus"))
        let decisionOnly = Facts.reviewLines(SharedFixtures.pullRequestDetail { $0.reviewDecision = .reviewRequired })
        #expect(decisionOnly == ["Review required"])
        #expect(Facts.reviewLines(SharedFixtures.pullRequestDetail()).isEmpty)
    }

    @Test func checksAreTalliedFailedThenRunning() {
        let checks = [
            SharedFixtures.check("lint", .success), SharedFixtures.check("unit", .failure),
            SharedFixtures.check("ui", .running), SharedFixtures.check("deploy", .pending),
            SharedFixtures.check("docs", .cancelled, workflow: nil),
        ]
        let tally = Facts.tally(ProviderPage(items: checks, total: 9))
        #expect(tally.hasFailures)
        #expect(tally.listed.map(\.name) == ["unit", "ui", "deploy"])
        #expect(tally.headline.components(separatedBy: " · ").count == 4)
        let clean = Facts.tally(ProviderPage(items: [SharedFixtures.check("lint", .success)], total: 1))
        #expect(!clean.hasFailures)
        #expect(clean.headline.components(separatedBy: " · ").count == 1)
        let many = (0..<10).map { SharedFixtures.check("c\($0)", .failure) }
        #expect(Facts.tally(ProviderPage(items: many)).listed.count == Facts.listedCheckLimit)
        #expect(Facts.checkName(checks[1]) == "CI · unit")
        #expect(Facts.checkName(checks[4]) == "docs")
        #expect(Facts.hasChecks(ProviderPage(items: [], total: 3)))
        #expect(!Facts.hasChecks(ProviderPage(items: [])))
        #expect(Facts.hasChecks(ProviderPage(items: checks)))
    }

    @Test func workflowFacts() {
        let run = SharedFixtures.workflowDetail(jobs: [])
        #expect(Facts.workflow(run) == "CI · push")
        #expect(Facts.noJobsText(SharedFixtures.workflowDetail(jobs: [], total: 0)) == String(localized: "No jobs"))
        #expect(Facts.noJobsText(run) == String(localized: "Jobs unavailable"))
        let start = SharedFixtures.now
        #expect(Facts.elapsed(start, start.addingTimeInterval(65)) == DeckFormat.duration(65))
        #expect(Facts.elapsed(nil, start).isEmpty)
        #expect(Facts.elapsed(start, nil).isEmpty)
        #expect(ProviderDetailView.elapsed(start, start.addingTimeInterval(5)) == DeckFormat.duration(5))
    }

    @Test func deploymentFacts() throws {
        let alias = try #require(URL(string: "https://web.example.com"))
        let duplicate = try #require(URL(string: "https://one.vercel.app"))
        let unsafe = try #require(URL(string: "http://insecure.example.com"))
        let detail = SharedFixtures.deploymentDetail(aliases: [alias, duplicate, unsafe])
        #expect(Facts.addresses(detail).map(\.host) == ["one.vercel.app", "web.example.com"])
        let build = try #require(Facts.build(detail))
        #expect(build.contains(DeckFormat.duration(42)))
        #expect(Facts.build(SharedFixtures.deploymentDetail(duration: -5)) != nil, "the age alone")
        var bare = SharedFixtures.deploymentDetail(duration: nil)
        bare.createdAt = nil
        #expect(Facts.build(bare) == nil)
        #expect(Facts.source(detail) == "main · 1a2b3c4")
        #expect(Facts.failureReason(detail) == "Build failed")
        #expect(Facts.failureReason(SharedFixtures.deploymentDetail(state: .success)) == nil)
        #expect(Facts.project(detail) == "web · nextjs · team")
        #expect(Facts.project(SharedFixtures.deploymentDetail(project: nil)) == "web-fallback · team")
    }

    @Test func failureJoinsStatusAndDiagnostic() {
        let target = ProviderTarget.pullRequest(repository: SharedFixtures.repository, number: 1)
        let report = ProviderDetailReport(target: target, status: .unavailable, diagnostic: "gh: not logged in")
        #expect(Facts.failure(report) == ProviderText.status("Unavailable") + " · gh: not logged in")
        let empty = ProviderDetailReport(target: target, status: .unavailable, diagnostic: "")
        #expect(Facts.failure(empty) == ProviderText.status("Unavailable"))
    }
}
