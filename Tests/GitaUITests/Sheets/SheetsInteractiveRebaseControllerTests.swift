import AppKit
import Foundation
import GitaCore
import Testing

@testable import GitaUI

@MainActor
@Suite struct SheetsInteractiveRebaseControllerTests {
    private func button(_ id: String, _ sheet: InteractiveRebaseController) throws -> NSButton {
        try SheetsSupport.require(id, in: sheet.window, as: NSButton.self)
    }

    @Test func reordersAndDropsCommitsInTheSubmittedPlan() async throws {
        let rebase = try await SheetsRebaseFixture()
        let sheet = rebase.sheet()
        try await SheetsRebaseFixture.loaded(sheet)
        #expect(sheet.numberOfRows(in: sheet.table) == 3)
        #expect(sheet.selectedID == rebase.ids[0])
        #expect(!sheet.upButton.isEnabled && sheet.downButton.isEnabled)
        let apply = try button("rebase.apply", sheet)
        #expect(!apply.isEnabled)
        sheet.downButton.performClick(nil)
        #expect(sheet.plan.steps.map(\.commitID) == [rebase.ids[1], rebase.ids[0], rebase.ids[2]])
        #expect(sheet.orderLabel.stringValue == "Replay order")
        sheet.upButton.performClick(nil)
        #expect(!sheet.plan.orderChanged)
        sheet.moveCommitLater()
        try SheetsRebaseFixture.choose(.drop, row: 2, in: sheet)
        #expect(sheet.plan.step(rebase.ids[2])?.action == .drop)
        #expect(sheet.selectedID == rebase.ids[2])
        #expect(sheet.window?.isDocumentEdited == true)
        #expect(apply.isEnabled)
        apply.performClick(nil)
        try await SheetsSupport.wait { sheet.activity.isFinishing }
        let submitted = try #require(rebase.submitted.first)
        #expect(submitted.plan.commits.map(\.id) == rebase.ids)
        #expect(submitted.steps.map(\.commitID) == [rebase.ids[1], rebase.ids[0], rebase.ids[2]])
        #expect(submitted.steps.map(\.action) == [.pick, .pick, .drop])
    }

    @Test func submitsTheRewordedMessage() async throws {
        let rebase = try await SheetsRebaseFixture()
        let sheet = rebase.sheet()
        try await SheetsRebaseFixture.loaded(sheet)
        try SheetsRebaseFixture.choose(.reword, row: 1, in: sheet)
        #expect(!sheet.editorGroup.isHidden)
        try await SheetsSupport.wait { sheet.plan.originals[rebase.ids[1]] != nil }
        #expect(sheet.editor.string == "Add two\n")
        #expect(sheet.editor.isEditable)
        SheetsSupport.type("Second commit\n\nWith a body.\n", into: sheet.editor)
        #expect(sheet.plan.drafts[rebase.ids[1]] != nil)
        // Selecting another commit hides the editor; coming back restores the draft.
        sheet.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        #expect(sheet.editorGroup.isHidden)
        sheet.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        #expect(sheet.editor.string == "Second commit\n\nWith a body.\n")
        try button("rebase.apply", sheet).performClick(nil)
        try await SheetsSupport.wait { sheet.activity.isFinishing }
        let steps = try #require(rebase.submitted.first).steps
        #expect(steps.map(\.action) == [.pick, .reword, .pick])
        #expect(steps.map(\.message) == [nil, "Second commit\n\nWith a body.\n", nil])
    }

    @Test func aFailedMessageReadCanBeRetried() async throws {
        let rebase = try await SheetsRebaseFixture()
        let service = rebase.fixture.service
        var reads = 0
        let sheet = rebase.sheet(onMessage: { id in
            reads += 1
            if reads == 1 { throw SheetsFailure("message unreadable") }
            return try await service.commitDetails(ref: id).message
        })
        try await SheetsRebaseFixture.loaded(sheet)
        try SheetsRebaseFixture.choose(.reword, row: 0, in: sheet)
        try await SheetsSupport.wait { sheet.plan.messageErrors[rebase.ids[0]] != nil }
        #expect(!sheet.retryButton.isHidden && !sheet.editor.isEditable)
        #expect(sheet.plan.validation?.contains("message unreadable") == true)
        sheet.retryButton.performClick(nil)
        try await SheetsSupport.wait { sheet.plan.originals[rebase.ids[0]] != nil }
        #expect(sheet.retryButton.isHidden)
        #expect(sheet.editor.string == "Add one\n")
    }

    @Test func editorInputLimitsAndCommands() async throws {
        let rebase = try await SheetsRebaseFixture()
        let sheet = rebase.sheet()
        try await SheetsRebaseFixture.loaded(sheet)
        try SheetsRebaseFixture.choose(.reword, row: 0, in: sheet)
        try await SheetsSupport.wait { sheet.plan.originals[rebase.ids[0]] != nil }
        let editor = sheet.editor
        let start = NSRange(location: 0, length: 0)
        #expect(sheet.textView(editor, shouldChangeTextIn: start, replacementString: "ok"))
        #expect(sheet.textView(editor, shouldChangeTextIn: start, replacementString: nil))
        #expect(sheet.textView(NSTextView(), shouldChangeTextIn: start, replacementString: "\u{0}"))
        #expect(!sheet.textView(editor, shouldChangeTextIn: start, replacementString: "\u{0}"))
        #expect(sheet.inputError == "Messages must fit in 64 KiB and cannot contain NUL characters.")
        #expect(sheet.plan.status(sheet.activity, .init(inputError: sheet.inputError)).isError)
        #expect(!sheet.textView(editor, doCommandBy: #selector(NSResponder.moveLeft(_:))))
        sheet.textDidChange(Notification(name: NSText.didChangeNotification, object: NSTextView()))
        let alerts = SheetsAlertRecorder()
        alerts.response = 1
        alerts.install(on: sheet)
        #expect(sheet.textView(editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(alerts.alerts.count == 1 && sheet.activity.isFinishing)
    }

    @Test func reloadingADirtyPlanAsksAndAFailedApplyNeedsAFreshReview() async throws {
        let rebase = try await SheetsRebaseFixture()
        let sheet = rebase.sheet(onApply: { _, _ in throw SheetsFailure("rebase refused") })
        try await SheetsRebaseFixture.loaded(sheet)
        try SheetsRebaseFixture.choose(.drop, row: 0, in: sheet)
        let alerts = SheetsAlertRecorder()
        alerts.response = 0
        alerts.install(on: sheet)
        let reload = try button("rebase.reload", sheet)
        reload.performClick(nil)
        #expect(alerts.alerts.first?.buttons.map(\.title) == ["Keep Editing", "Discard and Reload"])
        #expect(sheet.plan.isDirty)
        alerts.response = 1
        reload.performClick(nil)
        try await SheetsSupport.wait { !sheet.isLoadingPlan && !sheet.plan.isDirty }
        try SheetsRebaseFixture.choose(.drop, row: 0, in: sheet)
        let apply = try button("rebase.apply", sheet)
        apply.performClick(nil)
        try await SheetsSupport.wait { !sheet.isApplying && !apply.isEnabled }
        #expect(sheet.review == .stale("rebase refused"))
        #expect(sheet.plan.status(sheet.activity, .init(review: sheet.review)).isError)
        try button("rebase.cancel", sheet).performClick(nil)
        #expect(alerts.alerts.count == 3 && sheet.activity.isFinishing)
    }

    @Test(arguments: [true, false])
    func anUnavailablePlanIsReported(throwing: Bool) async throws {
        let rebase = try await SheetsRebaseFixture()
        let base = rebase.base
        let sheet = rebase.sheet(onLoad: {
            if throwing { throw SheetsFailure("cannot read range") }
            return GitInteractiveRebasePlan(base: base, headID: base.id, branch: nil, commits: [], identity: "x")
        })
        SheetsSupport.present(sheet)
        try await SheetsSupport.wait { !sheet.isLoadingPlan }
        #expect(sheet.plan.plan == nil && sheet.review.error != nil)
        #expect(sheet.empty.stringValue == "Plan unavailable" && !sheet.empty.isHidden)
        #expect(try !button("rebase.apply", sheet).isEnabled)
    }
}
