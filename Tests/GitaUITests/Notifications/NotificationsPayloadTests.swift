import Foundation
import GitaCore
import Testing

@testable import GitaUI

/// What a provider notification may carry, and the keys that make each one announce once.
@MainActor
@Suite struct NotificationsPayloadTests {
    typealias NF = NotificationsFixtures
    typealias PL = ProviderNotificationPayload

    @Test func sourcesMustBeHostedIdentities() {
        #expect(PL.validSource("github:owner/app", provider: .github))
        #expect(!PL.validSource("github:Owner/app", provider: .github))
        #expect(!PL.validSource("gitlab:owner/app", provider: .github))
        #expect(!PL.validSource("github:owner", provider: .github))
        #expect(PL.validSource("vercel:team_1/prj_1", provider: .vercel))
        #expect(!PL.validSource("vercel:team_1/app", provider: .vercel))
        #expect(!PL.validSource("vercel:team 1/prj_1", provider: .vercel))
        #expect(!PL.validSource("vercel:prj_1", provider: .vercel))
        #expect(!PL.validSource("github:owner/app", provider: .vercel))
        #expect(!PL.validSource("orca:x", provider: .orca))
    }

    @Test func entityKeysIdentifyOneExactItem() {
        let run = ProviderTarget.workflowRun(repository: "owner/app", runID: 5, attempt: 2)
        #expect(PL.entityKey(source: NF.github, target: run) != nil)
        #expect(PL.entityKey(source: "github:owner/other", target: run) == nil)
        #expect(
            PL.entityKey(source: NF.github, target: .workflowRun(repository: "owner/app", runID: 0, attempt: 1)) == nil)
        #expect(
            PL.entityKey(source: NF.github, target: .workflowRun(repository: "owner/app", runID: 1, attempt: 0)) == nil)
        #expect(PL.entityKey(source: NF.github, target: .pullRequest(repository: "owner/app", number: 3)) != nil)
        #expect(PL.entityKey(source: NF.github, target: .pullRequest(repository: "owner/app", number: 0)) == nil)
        let deployment = ProviderTarget.deployment(reference: "app-1.vercel.app", projectName: "app", scope: nil)
        #expect(PL.entityKey(source: NF.vercel, target: deployment) != nil)
        #expect(PL.entityKey(source: NF.github, target: deployment) == nil)
        #expect(
            PL.entityKey(source: NF.vercel, target: .deployment(reference: "dpl_abc", projectName: "-app", scope: nil))
                == nil)
        #expect(
            PL.entityKey(source: NF.vercel, target: .deployment(reference: "dpl_abc", projectName: "app", scope: ".."))
                == nil)
        // Different lists never join to the same key.
        let a = PL.entityKey(source: NF.github, target: .pullRequest(repository: "owner/app", number: 12))
        let b = PL.entityKey(source: NF.github, target: .pullRequest(repository: "owner/app", number: 1))
        #expect(a != b)
    }

    @Test func outcomeKeysSeparateEventsAndNeedAFinishedLegacyState() {
        let failed = NF.destination(NF.run(), event: .checksFailed)
        var legacy = failed
        legacy.event = nil
        #expect(PL.outcomeKey(failed) != nil)
        #expect(PL.outcomeKey(legacy) != nil)
        #expect(PL.outcomeKey(failed) != PL.outcomeKey(legacy))
        let running = ProviderNotificationDestination(
            schemaVersion: 1, repositoryPath: failed.repositoryPath, commonGitDirectoryPath: failed.repositoryPath,
            providerSourceID: NF.github, itemID: failed.itemID, target: failed.target, title: "CI", state: .running,
            branch: nil, commit: nil, url: nil, observedAt: Date())
        #expect(PL.outcomeKey(running) == nil)
        var pull = NF.destination(NF.pullRequest(), event: .pullRequestOpened)
        pull.event = nil
        #expect(PL.outcomeKey(pull) == nil)
    }

    @Test func encodingRoundTripsOnlyValidDestinations() throws {
        let destination = NF.destination(NF.deployment(), event: .previewReady, actor: nil)
        let data = try #require(PL.encode(destination))
        let decoded = try #require(PL.decode(data))
        #expect(decoded.itemID == destination.itemID && decoded.event == .previewReady)
        #expect(PL.decode(Data("{}".utf8)) == nil)
        #expect(PL.decode(Data(count: PL.byteLimit + 1)) == nil)
        #expect(PL.digest("a").count == 64)
        #expect(PL.digest("a") != PL.digest("b"))
        #expect(PL.date(Date()))
        #expect(!PL.date(Date().addingTimeInterval(3_600)))
        #expect(!PL.date(Date(timeIntervalSince1970: -1)))
    }

    @Test func validationRefusesEveryMalformedField() {
        let good = NF.destination(NF.run(), event: .checksFailed)
        #expect(PL.valid(good))
        let commit = String(repeating: "b", count: 64)
        let cases: [(String, ProviderNotificationDestination)] = [
            ("schema", good.with(.schemaVersion(2))),
            ("relative path", good.with(.repositoryPath("relative/app"))),
            ("unstandard path", good.with(.repositoryPath("/tmp/../tmp/app"))),
            ("empty title", good.with(.title(""))),
            ("control title", good.with(.title("a\u{7}b"))),
            ("short commit", good.with(.commit("abc"))),
            ("long actor", good.with(.actor(String(repeating: "x", count: 65)))),
            ("future", good.with(.observedAt(Date().addingTimeInterval(3_600)))),
            ("http", good.with(.url(URL(string: "http://github.com/owner/app/actions/runs/1")))),
            ("query", good.with(.url(URL(string: "https://github.com/owner/app/actions/runs/1?x=1")))),
            ("other run", good.with(.url(URL(string: "https://github.com/owner/app/actions/runs/2")))),
            ("other host", good.with(.url(URL(string: "https://example.com/owner/app/actions/runs/1")))),
            ("item", good.with(.itemID("github:run:9"))),
        ]
        for (name, destination) in cases {
            #expect(!PL.valid(destination), "\(name)")
        }
        #expect(PL.valid(good.with(.commit(commit))))
        #expect(PL.valid(good.with(.url(URL(string: "https://github.com/owner/app/actions/runs/1/attempts/1")))))
        #expect(PL.valid(good.with(.url(nil))))
    }

    @Test func pullRequestsAndDeploymentsValidateTheirOwnLinks() {
        let pull = NF.destination(NF.pullRequest(), event: .reviewRequested)
        #expect(PL.valid(pull))
        #expect(!PL.valid(pull.with(.url(URL(string: "https://github.com/owner/app/pull/8")))))
        #expect(!PL.valid(pull.with(.itemID("github:pr:8"))))
        #expect(PL.valid(pull.with(.url(nil))))
        var agentEvent = pull
        agentEvent.event = .agentFinished
        #expect(!PL.valid(agentEvent))

        let deployment = NF.destination(NF.deployment(), event: .previewReady)
        #expect(PL.valid(deployment))
        #expect(!PL.valid(deployment.with(.url(URL(string: "https://other.vercel.app")))))
        #expect(!PL.valid(deployment.with(.itemID("github:app-abc.vercel.app"))))
        #expect(PL.valid(deployment.with(.url(nil))))
        let byID = ProviderNotificationDestination(
            schemaVersion: 1, repositoryPath: deployment.repositoryPath,
            commonGitDirectoryPath: deployment.commonGitDirectoryPath, providerSourceID: NF.vercel,
            itemID: "vercel:dpl_123", target: .deployment(reference: "dpl_123", projectName: "app", scope: "team"),
            title: "Deployment", state: .success, branch: "main", commit: nil,
            url: URL(string: "https://anything.vercel.app"), observedAt: Date(), event: .previewReady)
        #expect(PL.valid(byID))
    }

    @Test func namesAndReferencesFollowTheProvidersRules() {
        #expect(PL.identifier("team_1-a"))
        #expect(!PL.identifier(""))
        #expect(!PL.identifier("a.b"))
        #expect(!PL.identifier(String(repeating: "a", count: 129)))
        #expect(PL.slug("my.app"))
        #expect(!PL.slug("."))
        #expect(!PL.slug("-x"))
        #expect(PL.repository("owner/app"))
        #expect(!PL.repository("owner/app/extra"))
        #expect(!PL.repository("owner/"))
        #expect(PL.deploymentReference("dpl_abc") == "dpl_abc")
        #expect(PL.deploymentReference("App-1.Vercel.App") == "app-1.vercel.app")
        #expect(PL.deploymentReference("https://app.vercel.app/") == "app.vercel.app")
        #expect(PL.deploymentReference("https://app.vercel.app/path") == nil)
        #expect(PL.deploymentReference("localhost") == nil)
        #expect(PL.deploymentReference("-bad.vercel.app") == nil)
        #expect(PL.deploymentReference("a_b.vercel.app") == nil)
        #expect(PL.deploymentReference("dpl_") == nil)
    }
}
