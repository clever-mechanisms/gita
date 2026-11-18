import AppKit
import Testing

@testable import GitaCore
@testable import GitaUI

/// The Merge button beside Refresh: shown when the account may merge, its method picked from the menu, and a merge
/// sent only once the confirmation is accepted.
@MainActor
@Suite("Pull request merge")
struct PullRequestMergeTests {
    private func open(_ runner: ReviewTestRunner = ReviewTestRunner()) async throws -> PullRequestReviewController {
        UITestSupport.bootstrap()
        let controller = PullRequestReviewController(
            target: try #require(ReviewTestRunner.item.target), root: URL(fileURLWithPath: "/tmp"),
            service: PullRequestReviewService(runner: runner))
        try await SetupTestSupport.waitUntil("the pull request loads") { !controller.state.isLoading }
        return controller
    }

    private func answering(
        _ response: NSApplication.ModalResponse, asked: @escaping (NSAlert) -> Void
    ) -> AlertPresenter {
        AlertPresenter { alert, _, completion in
            asked(alert)
            completion(response)
        }
    }

    @Test func mergesWithThePickedMethodAfterTheConfirmation() async throws {
        let runner = ReviewTestRunner()
        let controller = try await open(runner)
        let control = controller.reviewView.merge
        #expect(!control.isHidden && control.mergeButton.isEnabled)
        #expect(controller.state.mergeMethod == .squash, "GitHub's suggested method comes first")
        #expect(control.mergeButton.accessibilityLabel() == String(localized: "Squash and merge"))
        let menu = control.menu()
        let titles = menu.items.map { $0.attributedTitle?.string.components(separatedBy: "\n").first }
        #expect(titles == PullRequestMergeMethod.allCases.map(\.localizedTitle))
        #expect(menu.items.map(\.state) == [.off, .on, .off])
        #expect(menu.items[1].attributedTitle?.string.contains("3 commits") == true)
        menu.performActionForItem(at: 2)
        #expect(controller.state.mergeMethod == .rebase)
        #expect(control.mergeButton.accessibilityLabel() == String(localized: "Rebase and merge"))

        var question = ""
        controller.alerts = answering(.alertSecondButtonReturn) { question = $0.messageText }
        control.mergeButton.onClick?()
        #expect(question == String(localized: "Rebase and merge this pull request into main?"))
        #expect(runner.mutations.isEmpty, "Cancel merges nothing")

        controller.alerts = answering(.alertFirstButtonReturn) { _ in }
        control.mergeButton.onClick?()
        try await SetupTestSupport.waitUntil("the merge is sent") {
            runner.mutations.count == 1 && !controller.state.isSending && !controller.state.isLoading
        }
        #expect(runner.mutations.first == GitHubReviewQueries.merge)
        #expect(controller.state.notice == .init(text: String(localized: "Pull request merged."), isError: false))
    }

    @Test func showsOnlyWhatTheAccountCanMerge() async throws {
        let reader = try await open(ReviewTestRunner(permission: "READ"))
        #expect(reader.reviewView.merge.isHidden, "no Merge button without write access")
        let merged = try await open(ReviewTestRunner(lifecycle: "MERGED"))
        #expect(merged.reviewView.merge.isHidden)
        let draft = try await open(ReviewTestRunner(isDraft: true))
        #expect(!draft.reviewView.merge.isHidden && !draft.reviewView.merge.mergeButton.isEnabled)
        #expect(draft.reviewView.merge.mergeButton.toolTip == String(localized: "This pull request is still a draft."))
        let conflicting = try await open(ReviewTestRunner(mergeable: "CONFLICTING"))
        #expect(conflicting.state.mergeProblem?.contains("conflicts") == true)
        conflicting.alerts = answering(.alertFirstButtonReturn) { _ in Issue.record("no confirmation while blocked") }
        conflicting.confirmMerge()
        #expect(!conflicting.state.isSending)
    }

    @Test func methodsFollowTheRepository() {
        var options = PullRequestMergeOptions(methods: [.merge, .rebase], preferred: .squash, viewerCanMerge: true)
        #expect(options.defaultMethod == .merge, "a suggestion the repository no longer allows is passed over")
        options.preferred = .rebase
        #expect(options.defaultMethod == .rebase)
        #expect(PullRequestMergeOptions().defaultMethod == nil)
        #expect(ReviewMergeControl.buttonTitle(.merge) == String(localized: "Merge pull request"))
        #expect(ReviewMergeControl.buttonTitle(nil) == String(localized: "Merge pull request"))
        for method in PullRequestMergeMethod.allCases { #expect(!method.explanation(commits: 2).isEmpty) }
        var state = PullRequestReviewState()
        #expect(!state.showsMerge && state.mergeProblem == nil && state.mergeExplanation.isEmpty)
        #expect(state.mergeQuestion.contains(String(localized: "the base branch")))
        state.pickedMergeMethod = .squash
        #expect(state.mergeMethod == nil, "nothing to merge before the pull request loads")
    }
}
