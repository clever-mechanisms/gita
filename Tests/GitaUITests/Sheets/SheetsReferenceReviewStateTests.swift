import Foundation
import GitaCore
import Testing

@testable import GitaUI

private typealias Fixtures = SheetsReferenceFixtures

@Suite struct SheetsReferenceReviewStateTests {
    private static let tagCommit = SheetsSupport.commit(Fixtures.commitID, subject: "Tagged")

    @Test(arguments: [
        (ReferenceReviewRequest.renameBranch(nil), "Rename Branch", "Rename", false, false),
        (.deleteBranch("refs/heads/topic"), "Delete Branch", "Delete Local Branch", true, false),
        (.deleteBranch(nil), "Delete Branch", "Delete Local Branch", true, true),
        (.setUpstream(nil), "Set Upstream", "Set Upstream", false, false),
        (.createTag(tagCommit), "Create Tag", "Create Tag", false, false),
        (.deleteTag(nil), "Delete Tag", "Delete Local Tag", true, true),
    ])
    func requests(
        request: ReferenceReviewRequest, title: String, apply: String, destructive: Bool, picker: Bool
    ) {
        let state = ReferenceReviewState(request: request, references: Fixtures.all)
        #expect(state.title == title)
        #expect(state.isDestructive == destructive)
        #expect(state.needsSourcePicker == picker)
        if case .setUpstream = request {
            #expect(state.upstreamChoice == .unavailable)
        } else {
            #expect(state.applyTitle == apply)
        }
    }

    @Test func renameDefaultsToTheCurrentBranchAndItsName() {
        let state = ReferenceReviewState(request: .renameBranch(nil), references: Fixtures.all)
        #expect(state.selectedSource == "refs/heads/main")
        #expect(state.name == "main")
        #expect(state.isRenaming && !state.isTracking && !state.isCreatingTag)
        let unknown = ReferenceReviewState(request: .renameBranch("refs/heads/gone"), references: [])
        #expect(unknown.name == "gone")
        let odd = ReferenceReviewState(request: .renameBranch("HEAD"), references: [])
        #expect(odd.name == "HEAD")
        let none = ReferenceReviewState(request: .renameBranch(nil), references: [Fixtures.topic])
        #expect(none.selectedSource == nil)
        #expect(none.restriction == "No current branch is selected.")
    }

    @Test func pickersOfferBranchesOrTags() {
        let branches = ReferenceReviewState(request: .deleteBranch(nil), references: Fixtures.all)
        #expect(branches.sourceChoices.map(\.title) == ["Choose a branch", "main", "topic"])
        #expect(branches.selectedSource == nil)
        #expect(branches.sourceKind == .branch)
        var tags = ReferenceReviewState(request: .deleteTag(nil), references: Fixtures.all)
        #expect(tags.sourceChoices.map(\.title) == ["Choose a tag", "v1"])
        #expect(tags.sourceKind == .tag)
        let noSource = tags.beginSourceLoad()
        #expect(noSource == nil)
        tags.chooseSource(at: 9)
        #expect(tags.sourceIndex == 0)
        tags.chooseSource(at: 1)
        #expect(tags.selectedSource == "refs/tags/v1")
        #expect(tags.upstreamChoices.map(\.title) == ["Not loaded"])
        let tagSource = tags.beginSourceLoad()
        #expect(tagSource == "refs/tags/v1")
        #expect(tags.sourceLoading)
        tags.cancelLoads()
        #expect(!tags.sourceLoading)
    }

    @Test func aLoadOfTheWrongReferenceFails() {
        var state = ReferenceReviewState(request: .deleteBranch("refs/heads/topic"), references: Fixtures.all)
        let expected = state.beginSourceLoad()
        #expect(expected == "refs/heads/topic")
        let tagDetails = Fixtures.details(Fixtures.tag)
        let loadsUpstream = state.finishSourceLoad(.success(tagDetails), expected: "refs/heads/topic")
        #expect(!loadsUpstream)
        #expect(state.errorMessage == "The selected reference is unavailable or has a different type.")
        #expect(state.failure?.kind == .source)
        state.editName("ignored")
        #expect(state.errorMessage != nil)
        _ = state.beginSourceLoad()
        let afterFailure = state.finishSourceLoad(
            .failure(SheetsFailure("read failed")), expected: "refs/heads/topic")
        #expect(!afterFailure)
        #expect(state.errorMessage == "read failed")
    }

    @Test func oneReadRunsAtATime() {
        let source = Fixtures.details(Fixtures.main, .init(upstream: Fixtures.upstream()))
        var state = ReferenceReviewState(request: .setUpstream(nil), references: Fixtures.all)
        let expected = state.beginSourceLoad()
        #expect(state.read == .source)
        _ = state.finishSourceLoad(.success(source), expected: expected ?? "")
        #expect(state.read == .idle)
        _ = state.beginUpstreamLoad()
        #expect(state.read == .upstream && state.upstreamLoading && !state.sourceLoading)
        // Reading the source again stops waiting for the upstream, without the controller's help.
        _ = state.beginSourceLoad()
        #expect(state.read == .source && !state.upstreamLoading)
        _ = state.beginUpstreamLoad()
        #expect(state.read == .source)
        state.cancelLoads()
        #expect(state.read == .idle)
    }

    @Test func aFailureCarriesItsMessage() {
        var state = ReferenceReviewState(request: .createTag(Self.tagCommit), references: Fixtures.all)
        state.applyFailed(SheetsFailure(String(repeating: "x", count: ReviewText.errorLimit + 10)))
        #expect(state.failure?.kind == .apply && state.errorMessage?.count == ReviewText.errorLimit)
        state.beginApply()
        #expect(state.failure == nil && state.errorMessage == nil)
    }

    @Test func trackingLoadsTheConfiguredUpstream() {
        let source = Fixtures.details(Fixtures.main, .init(upstream: Fixtures.upstream()))
        var state = ReferenceReviewState(request: .setUpstream(nil), references: Fixtures.all)
        let expected = state.beginSourceLoad()
        let loadsUpstream = state.finishSourceLoad(.success(source), expected: expected ?? "")
        #expect(loadsUpstream)
        #expect(
            state.upstreamChoices.map(\.title) == [
                "No upstream", "Local · main", "Local · topic", "Remote · origin/main",
            ])
        #expect(state.upstreamChoice == .reference("refs/remotes/origin/main"))
        let upstream = state.beginUpstreamLoad()
        #expect(upstream == "refs/remotes/origin/main")
        #expect(state.upstreamLoading)
        state.finishUpstreamLoad(.success(Fixtures.details(Fixtures.remoteMain)), expected: "refs/remotes/origin/main")
        #expect(state.upstreamDetails != nil)
        #expect(state.applyTitle == "Set Upstream")
        state.chooseUpstream(at: 0)
        #expect(state.upstreamChoice == .none)
        #expect(state.applyTitle == "Unset Upstream")
        let noUpstream = state.beginUpstreamLoad()
        #expect(noUpstream == nil)
        state.chooseUpstream(at: 99)
        #expect(state.upstreamIndex == 0)
        // An edited choice survives reloading the source.
        _ = state.beginSourceLoad()
        _ = state.finishSourceLoad(.success(source), expected: "refs/heads/main")
        #expect(state.upstreamChoice == .none)
    }

    @Test func anUpstreamMissingFromTheListIsAddedOrUnavailable() {
        let elsewhere = Fixtures.details(Fixtures.main, .init(upstream: Fixtures.upstream("refs/remotes/other/main")))
        let added = Fixtures.loaded(.setUpstream(nil), elsewhere)
        #expect(added.upstreamChoices.last?.title == "refs/remotes/other/main")
        #expect(added.upstreamChoice == .reference("refs/remotes/other/main"))
        let unnamed = Fixtures.details(Fixtures.main, .init(upstream: Fixtures.upstream(nil)))
        var unavailable = Fixtures.loaded(.setUpstream(nil), unnamed)
        #expect(unavailable.upstreamChoices.last?.title == "Configured upstream unavailable")
        #expect(unavailable.upstreamChoice == .unavailable)
        let unavailableLoad = unavailable.beginUpstreamLoad()
        #expect(unavailableLoad == nil)
        #expect(unavailable.errorMessage == "Choose an upstream branch or No upstream.")
        #expect(unavailable.pendingAction(.idle) == nil)
        let plain = Fixtures.loaded(.setUpstream(nil), Fixtures.details(Fixtures.main))
        #expect(plain.upstreamChoice == .none)
    }

    @Test func anUpstreamFromAnotherRepositoryOrOfTheWrongKindFails() {
        var state = Fixtures.loaded(.setUpstream(nil), Fixtures.details(Fixtures.main))
        state.chooseUpstream(at: 2)
        let expected = state.beginUpstreamLoad() ?? ""
        let foreign = Fixtures.details(Fixtures.topic, .init(root: URL(fileURLWithPath: "/tmp/elsewhere")))
        state.finishUpstreamLoad(.success(foreign), expected: expected)
        #expect(state.errorMessage == "The selected upstream is unavailable or has a different type.")
        #expect(state.failure?.kind == .upstream)
        _ = state.beginUpstreamLoad()
        state.finishUpstreamLoad(.success(Fixtures.details(Fixtures.tag)), expected: "refs/tags/v1")
        #expect(state.failure?.kind == .upstream)
        _ = state.beginUpstreamLoad()
        state.finishUpstreamLoad(.failure(SheetsFailure("gone")), expected: expected)
        #expect(state.errorMessage == "gone")
        var unloaded = ReferenceReviewState(request: .setUpstream(nil), references: Fixtures.all)
        let unloadedLoad = unloaded.beginUpstreamLoad()
        #expect(unloadedLoad == nil)
    }

    @Test func editsClearOnlyApplyErrors() {
        var state = ReferenceReviewState(
            request: .createTag(Self.tagCommit), references: Fixtures.all, hasRemotes: true)
        let tagLoad = state.beginSourceLoad()
        #expect(tagLoad == nil)
        state.applyFailed(SheetsFailure("exists"))
        #expect(state.failure?.kind == .apply)
        state.editName("v2")
        #expect(state.errorMessage == nil)
        state.applyFailed(SheetsFailure("exists"))
        state.setPushToAllRemotes(true)
        #expect(state.pushToAllRemotes && state.errorMessage == nil)
        state.applyFailed(SheetsFailure("exists"))
        state.editAnnotation("Notes")
        #expect(state.annotation == "Notes" && state.errorMessage == nil)
        state.applyFailed(SheetsFailure("exists"))
        state.beginApply()
        #expect(state.errorMessage == nil)
        var noRemotes = ReferenceReviewState(request: .createTag(Self.tagCommit), references: Fixtures.all)
        noRemotes.setPushToAllRemotes(true)
        #expect(!noRemotes.pushToAllRemotes)
        var rename = ReferenceReviewState(request: .renameBranch(nil), references: Fixtures.all)
        rename.setPushToAllRemotes(true)
        #expect(!rename.pushToAllRemotes)
    }

    @Test func aManualNameSurvivesLoading() {
        var state = ReferenceReviewState(request: .renameBranch("refs/heads/topic"), references: Fixtures.all)
        state.editName("feature")
        let expected = state.beginSourceLoad() ?? ""
        _ = state.finishSourceLoad(.success(Fixtures.details(Fixtures.topic)), expected: expected)
        #expect(state.name == "feature")
    }
}
