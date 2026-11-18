import AppKit
import Foundation
import GitaCore
import Testing

@testable import GitaUI

@Suite struct SheetsResetReviewStateTests {
    private static let target = SheetsSupport.objectID("a")

    private static func preview(target id: String = target, branch: String? = "main") -> GitResetPreview {
        GitResetPreview(
            target: SheetsSupport.commit(id), currentHeadID: SheetsSupport.objectID("b"), currentBranch: branch,
            trackedChangeCount: 2, untrackedFileCount: 1, identity: "identity")
    }

    @Test(arguments: [
        (GitResetMode.soft, false, "Reset", "Keep staged and working changes."),
        (.mixed, false, "Reset", "Unstage changes; keep working files."),
        (.hard, true, "Hard Reset", "Discard staged and working changes in tracked files."),
    ])
    func modes(mode: GitResetMode, destructive: Bool, title: String, effect: String) {
        var state = ResetReviewState(commitID: Self.target)
        state.select(mode)
        #expect(state.isDestructive == destructive)
        #expect(state.applyTitle == title)
        #expect(state.effect == effect)
    }

    @Test func loadingAPreviewEnablesApplying() throws {
        var state = ResetReviewState(commitID: Self.target)
        #expect(state.facts == nil)
        state.beginLoad()
        #expect(state.isLoading)
        #expect(state.status(.idle) == SheetStatus(message: "Loading reset preview…", isBusy: true))
        #expect(!state.canApply(.idle))
        state.finishLoad(.success(Self.preview()))
        #expect(state.canApply(.idle))
        let facts = try #require(state.facts)
        #expect(facts.text == "main · 2 tracked changes")
        #expect(facts.toolTip == "HEAD: \(SheetsSupport.objectID("b"))\n1 untracked files")
        state.select(.hard)
        #expect(!state.canApply(.idle))
        state.confirmsDiscard = true
        #expect(state.canApply(.idle))
        #expect(!state.canApply(.applying(refusedClose: false)))
    }

    @Test func detachedHeadFacts() throws {
        var state = ResetReviewState(commitID: Self.target)
        state.finishLoad(.success(Self.preview(branch: nil)))
        #expect(try #require(state.facts).text.hasPrefix("Detached HEAD"))
    }

    @Test func aDifferentTargetOrAFailureIsAnError() {
        var state = ResetReviewState(commitID: Self.target)
        state.finishLoad(.success(Self.preview(target: SheetsSupport.objectID("c"))))
        #expect(state.errorMessage == "The selected commit is unavailable.")
        #expect(state.status(.idle).isError)
        state.select(.soft)
        #expect(state.errorMessage != nil)
        state.finishLoad(.failure(SheetsFailure("read failed")))
        #expect(state.errorMessage == "read failed")
        state.finishLoad(.success(Self.preview()))
        state.applyFailed(SheetsFailure("apply failed"))
        state.select(.mixed)
        #expect(state.errorMessage == nil)
        state.applyFailed(SheetsFailure("apply failed"))
        state.beginApply()
        #expect(state.errorMessage == nil)
        state.beginLoad()
        state.cancelLoad()
        #expect(!state.isLoading && state.preview == nil)
    }

    @Test func aCancelledReadReturnsToIdleAndOnlyApplyErrorsClearOnAModeChange() {
        var state = ResetReviewState(commitID: Self.target)
        state.beginLoad()
        state.cancelLoad()
        guard case .idle = state.load else {
            Issue.record("Expected idle")
            return
        }
        #expect(state.status(.idle) == SheetStatus(message: ""))
        state.applyFailed(SheetsFailure("no preview"))
        #expect(state.errorMessage == nil)
        state.finishLoad(.failure(SheetsFailure("read failed")))
        state.cancelLoad()
        state.select(.hard)
        state.beginApply()
        #expect(state.errorMessage == "read failed" && state.preview == nil && !state.isLoading)
        state.beginLoad()
        state.confirmsDiscard = true
        state.finishLoad(.success(Self.preview()))
        state.applyFailed(SheetsFailure("refused"))
        #expect(state.errorMessage == "refused" && state.preview != nil && !state.canApply(.idle))
        state.select(.hard)
        #expect(state.errorMessage == nil && state.canApply(.idle))
        state.beginLoad()
        #expect(!state.confirmsDiscard && state.preview == nil && state.errorMessage == nil)
    }

    @Test func statusWhileApplying() {
        let state = ResetReviewState(commitID: Self.target)
        #expect(state.status(.applying(refusedClose: false)) == SheetStatus(message: "Resetting…", isBusy: true))
        #expect(
            state.status(.applying(refusedClose: true))
                == SheetStatus(message: "Wait for the reset to finish.", isBusy: true))
        #expect(state.status(.idle) == SheetStatus(message: ""))
    }
}

@MainActor
@Suite struct SheetsResetReviewControllerTests {
    private func makeSheet(
        _ fixture: SheetsRepository, commit: GitCommit,
        onApply: (@MainActor (GitResetPreview, GitResetMode) async throws -> Void)? = nil
    ) -> ResetReviewController {
        let service = fixture.service
        return ResetReviewController(
            commit: commit, onLoad: { try await service.resetPreview(to: commit.id) },
            onApply: onApply ?? { try await service.reset($0, mode: $1) })
    }

    @Test func hardResetNeedsTheDiscardConfirmation() async throws {
        let fixture = try SheetsRepository()
        let first = try fixture.commit("file.txt", "one\n", message: "First")
        try fixture.commit("file.txt", "two\n", message: "Second")
        try fixture.repository.write("file.txt", "dirty\n")
        let sheet = makeSheet(fixture, commit: try await fixture.gitCommit(first))
        let window = sheet.window
        SheetsSupport.present(sheet)
        try await SheetsSupport.wait { sheet.state.preview != nil }
        let apply = try SheetsSupport.require("reset.apply", in: window, as: NSButton.self)
        #expect(apply.isEnabled && apply.title == "Reset")
        SheetsSupport.choose(2, in: try SheetsSupport.require("reset.mode", in: window, as: NSPopUpButton.self))
        #expect(sheet.state.mode == .hard)
        #expect(!apply.isEnabled && apply.title == "Hard Reset")
        let discard = try SheetsSupport.require("reset.discard", in: window, as: NSButton.self)
        discard.performClick(nil)
        #expect(sheet.state.confirmsDiscard && apply.isEnabled)
        apply.performClick(nil)
        try await SheetsSupport.wait { sheet.activity.isFinishing }
        #expect(try fixture.head() == first)
        #expect(try String(contentsOf: fixture.url.appendingPathComponent("file.txt"), encoding: .utf8) == "one\n")
    }

    @Test func aFailedResetStaysOpenWithTheError() async throws {
        let fixture = try SheetsRepository()
        let first = try fixture.commit("file.txt", "one\n", message: "First")
        try fixture.commit("file.txt", "two\n", message: "Second")
        let sheet = makeSheet(fixture, commit: try await fixture.gitCommit(first)) { _, _ in
            throw SheetsFailure("reset refused")
        }
        SheetsSupport.present(sheet)
        try await SheetsSupport.wait { sheet.state.preview != nil }
        let window = sheet.window
        try SheetsSupport.require("reset.apply", in: window, as: NSButton.self).performClick(nil)
        try await SheetsSupport.wait { sheet.state.errorMessage != nil }
        #expect(sheet.state.errorMessage == "reset refused")
        #expect(!sheet.activity.isFinishing)
        let reload = try SheetsSupport.require("reset.reload", in: window, as: NSButton.self)
        reload.performClick(nil)
        #expect(sheet.state.isLoading)
        try await SheetsSupport.wait { !sheet.state.isLoading }
        #expect(sheet.state.errorMessage == nil)
        try SheetsSupport.require("reset.cancel", in: window, as: NSButton.self).performClick(nil)
        #expect(sheet.activity.isFinishing)
    }

    @Test func aMissingTargetCannotBeApplied() async throws {
        let fixture = try SheetsRepository()
        try fixture.commit("file.txt", "one\n", message: "First")
        let missing = SheetsSupport.commit(SheetsSupport.objectID("e"))
        let sheet = makeSheet(fixture, commit: missing)
        SheetsSupport.present(sheet)
        try await SheetsSupport.wait { !sheet.state.isLoading && sheet.state.errorMessage != nil }
        #expect(try !SheetsSupport.require("reset.apply", in: sheet.window, as: NSButton.self).isEnabled)
    }
}
