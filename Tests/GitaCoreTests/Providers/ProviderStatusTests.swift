import Foundation
import Testing

@testable import GitaCore

/// The typed provider vocabulary: connection statuses and pull request lifecycles.
@Suite struct ProviderStatusTests {
    @Test func brokenStatusesAreTheOnesWorthAPanelLine() {
        let broken: Set<ProviderStatus> = [
            .signInRequired, .accessDenied, .notInstalled, .offline, .timedOut, .unavailable, .updateCLI,
            .responseTooLarge, .projectChanged,
        ]
        let all: [ProviderStatus] = [
            .connected, .partial, .unavailable, .noRemote, .notGitHub, .notLinked, .notInstalled, .offline,
            .signInRequired, .accessDenied, .timedOut, .responseTooLarge, .updateCLI, .projectChanged,
            .repositoryChanged, .cancelled,
        ]
        for status in all {
            #expect(status.isBroken == broken.contains(status), "\(status)")
            #expect(status.localizedTitle == String(localized: String.LocalizationValue(status.rawValue)))
        }
    }

    @Test func aLoginFieldInAResponseIsNotASignInRequest() {
        let response = #"{"data":{"viewer":{"login":"me"},"repository":null},"errors":[{"type":"NOT_FOUND"}]}"#
        #expect(ProviderFailureClassifier.classify(response, tool: .gh, exitCode: 1).status != .signInRequired)
        for signedOut in [
            "To get started with GitHub CLI, please run:  gh auth login",
            "You are not logged into any GitHub hosts. To log in, run: gh auth login",
            "Error: No existing credentials found. Please run `vercel login`",
            "HTTP 401: Bad credentials",
        ] {
            #expect(ProviderFailureClassifier.classify(signedOut, tool: .gh, exitCode: 1).status == .signInRequired)
        }
    }

    @Test func gitHubStatesMapToLifecycles() {
        #expect(PullRequestLifecycle(gitHub: "OPEN") == .open)
        #expect(PullRequestLifecycle(gitHub: "CLOSED") == .closed)
        #expect(PullRequestLifecycle(gitHub: "MERGED") == .merged)
        #expect(PullRequestLifecycle(gitHub: "open") == .unknown)
        #expect(PullRequestLifecycle(gitHub: nil) == .unknown)
        #expect(PullRequestLifecycle.open.localizedTitle == ProviderText.status("Open"))
        #expect(PullRequestLifecycle.merged.localizedTitle == ProviderText.status("Merged"))
        #expect(PullRequestLifecycle.unknown.localizedTitle == ProviderText.status("Unknown"))
    }

    @Test func itemTokensStillLocalize() {
        #expect(ProviderText.status("Connected") == ProviderStatus.connected.localizedTitle)
        #expect(ProviderText.status("Cancelled") == ProviderStatus.cancelled.localizedTitle)
        #expect(ProviderText.status("not a token") == "not a token")
    }
}
