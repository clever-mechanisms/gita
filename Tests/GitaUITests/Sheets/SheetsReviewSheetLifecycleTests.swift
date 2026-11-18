import AppKit
import Foundation
import Testing

@testable import GitaUI

/// A minimal review sheet that records the lifecycle hooks it receives.
@MainActor
private final class SheetsProbeSheet: ReviewSheetController {
    var unsaved = false
    var prompt: DiscardPrompt? = DiscardPrompt(
        message: "Discard?", information: "Edits are lost.", closeTitle: "Discard", quitTitle: "Quit",
        keepEditingFirst: false)
    private(set) var presentedCount = 0
    private(set) var cancelCount = 0
    private(set) var updateCount = 0
    private(set) var finishedCount = 0
    let loads = LatestTask()

    init() {
        UITestSupport.bootstrap()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled, .closable],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        super.init(sheet: window)
    }

    override func sheetDidPresent() { presentedCount += 1 }
    override func cancelLoads() { cancelCount += 1 }
    override func updateControls() { updateCount += 1 }
    override func sheetWillFinish() { finishedCount += 1 }
    override var hasUnsavedChanges: Bool { unsaved }
    override var discardPrompt: DiscardPrompt? { prompt }
    var refused: Bool { activity.refusedClose }
    var finishing: Bool { activity.isFinishing }
}

@MainActor
@Suite struct SheetsReviewSheetLifecycleTests {
    @Test func presentsOnceAndNotWhileFinishing() {
        let sheet = SheetsProbeSheet()
        SheetsSupport.present(sheet)
        SheetsSupport.present(sheet)
        #expect(sheet.presentedCount == 1)
        let closed = SheetsProbeSheet()
        closed.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        SheetsSupport.present(closed)
        #expect(closed.presentedCount == 0)
        #expect(closed.cancelCount == 1)
    }

    @Test func closingWithoutEditsFinishes() throws {
        let sheet = SheetsProbeSheet()
        let window = try #require(sheet.window)
        #expect(!sheet.windowShouldClose(window))
        #expect(sheet.finishing)
        #expect(sheet.finishedCount == 1)
        #expect(sheet.windowShouldClose(window))
        sheet.requestClose()
        #expect(sheet.finishedCount == 1)
    }

    @Test(arguments: [0, 1])
    func closingWithEditsAsks(answer: Int) throws {
        let sheet = SheetsProbeSheet()
        sheet.unsaved = true
        let alerts = SheetsAlertRecorder()
        alerts.response = answer
        alerts.install(on: sheet)
        sheet.close()
        let alert = try #require(alerts.alerts.first)
        #expect(alert.messageText == "Discard?")
        #expect(alert.buttons.map(\.title) == ["Discard", "Keep Editing"])
        #expect(sheet.finishing == (answer == 0))
    }

    @Test func keepEditingFirstPutsDiscardSecond() throws {
        let sheet = SheetsProbeSheet()
        sheet.unsaved = true
        sheet.prompt?.keepEditingFirst = true
        let alerts = SheetsAlertRecorder()
        alerts.response = 1
        alerts.install(on: sheet)
        sheet.cancelOperation(nil)
        #expect(try #require(alerts.alerts.first).buttons.map(\.title) == ["Keep Editing", "Discard"])
        #expect(sheet.finishing)
    }

    @Test func aPromptOnScreenBlocksOtherCloses() {
        let sheet = SheetsProbeSheet()
        sheet.unsaved = true
        let alerts = SheetsAlertRecorder()
        alerts.response = nil
        alerts.install(on: sheet)
        sheet.cancelReview()
        #expect(alerts.hasPending)
        sheet.requestClose()
        #expect(alerts.alerts.count == 1)
        var replies: [Bool] = []
        sheet.requestApplicationTermination { replies.append($0) }
        #expect(replies == [false])
        sheet.finish(.cancel)
        #expect(!sheet.finishing)
        alerts.answer(1)
        #expect(!sheet.finishing)
    }

    @Test func aLateAnswerAfterFinishingCancels() {
        let sheet = SheetsProbeSheet()
        sheet.unsaved = true
        let alerts = SheetsAlertRecorder()
        alerts.response = nil
        alerts.install(on: sheet)
        var cancelled = false
        sheet.requestApplicationTermination { cancelled = !$0 }
        sheet.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        alerts.answer(0)
        #expect(cancelled)
    }

    @Test func terminationApprovesDiscardOrRefuses() {
        let plain = SheetsProbeSheet()
        var replies: [Bool] = []
        plain.requestApplicationTermination { replies.append($0) }
        plain.dismissForApprovedTermination()
        #expect(replies == [true])
        #expect(plain.finishing)

        for (answer, expected) in [(0, true), (1, false)] {
            let edited = SheetsProbeSheet()
            edited.unsaved = true
            let alerts = SheetsAlertRecorder()
            alerts.response = answer
            alerts.install(on: edited)
            var reply: Bool?
            edited.requestApplicationTermination { reply = $0 }
            #expect(reply == expected)
            #expect(alerts.alerts.first?.buttons.first?.title == "Quit")
        }
    }

    @Test func confirmDiscardWithoutAnActiveSheetCancels() throws {
        let sheet = SheetsProbeSheet()
        sheet.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        var cancelled = false
        var completed = false
        sheet.confirmDiscard(
            try #require(sheet.prompt), action: "Go", onCancel: { cancelled = true }, then: { completed = true })
        #expect(cancelled && !completed)
    }

    @Test func applyingBlocksClosingUntilItEnds() async throws {
        let sheet = SheetsProbeSheet()
        let release = SheetsToggle(false)
        sheet.runApply {
            while !release.isOn { try await Task.sleep(for: .milliseconds(2)) }
        } onFailure: { _ in
        }
        #expect(sheet.isApplying)
        sheet.requestClose()
        #expect(sheet.refused)
        var replies: [Bool] = []
        sheet.requestApplicationTermination { replies.append($0) }
        #expect(replies == [false])
        sheet.dismissForApprovedTermination()
        #expect(!sheet.finishing)
        sheet.runApply({}, onFailure: { _ in })
        release.isOn = true
        try await SheetsSupport.wait { sheet.finishing }
        #expect(!sheet.isApplying)
    }

    @Test func applyingWaitsWhileAConfirmationIsOnScreen() async throws {
        let sheet = SheetsProbeSheet()
        sheet.unsaved = true
        let alerts = SheetsAlertRecorder()
        alerts.response = nil
        alerts.install(on: sheet)
        sheet.requestClose()
        #expect(alerts.hasPending)
        var ran = false
        sheet.runApply({ ran = true }, onSuccess: {}, onFailure: { _ in })
        await SheetsSupport.settle()
        #expect(!ran && !sheet.isApplying)
        alerts.answer(1)
        #expect(!sheet.finishing)
    }

    @Test(arguments: [false, true])
    func aSheetClosedUnderItsMutationHearsNothingOfTheResult(fails: Bool) async throws {
        let sheet = SheetsProbeSheet()
        let release = SheetsToggle(false)
        var reported = false
        sheet.runApply(
            {
                while !release.isOn { try await Task.sleep(for: .milliseconds(2)) }
                if fails { throw SheetsFailure("late") }
            }, onSuccess: { reported = true }, onFailure: { _ in reported = true })
        sheet.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        #expect(sheet.finishing && sheet.isApplying)
        var replies: [Bool] = []
        sheet.requestApplicationTermination { replies.append($0) }
        #expect(replies == [false])
        release.isOn = true
        try await SheetsSupport.wait { !sheet.isApplying }
        await SheetsSupport.settle()
        #expect(!reported && sheet.finishing)
    }

    @Test func applyReportsSuccessOrFailure() async throws {
        let sheet = SheetsProbeSheet()
        var succeeded = false
        sheet.runApply({}, onSuccess: { succeeded = true }, onFailure: { _ in })
        try await SheetsSupport.wait { succeeded }
        #expect(!sheet.finishing)
        var failure: String?
        sheet.runApply({ throw SheetsFailure("nope") }, onFailure: { failure = $0.localizedDescription })
        try await SheetsSupport.wait { failure != nil }
        #expect(failure == "nope")
        #expect(!sheet.isApplying)
    }

    @Test func startLoadDeliversUnlessFinishing() async throws {
        let sheet = SheetsProbeSheet()
        var begun = 0
        var delivered: [Int] = []
        sheet.startLoad(
            sheet.loads, { 3 }, begin: { begun += 1 },
            then: { if case .success(let value) = $0 { delivered.append(value) } })
        try await SheetsSupport.wait { !delivered.isEmpty }
        #expect(begun == 1 && delivered == [3])
        let release = SheetsToggle(false)
        sheet.startLoad(
            sheet.loads,
            {
                while !release.isOn { try await Task.sleep(for: .milliseconds(2)) }
                return 4
            }, begin: { begun += 1 }, then: { if case .success(let value) = $0 { delivered.append(value) } })
        sheet.finish(.cancel)
        release.isOn = true
        await SheetsSupport.settle()
        try await Task.sleep(for: .milliseconds(30))
        #expect(delivered == [3])
        sheet.startLoad(sheet.loads, { 5 }, begin: { begun += 1 }, then: { _ in })
        #expect(begun == 2)
    }

    @Test func finishingAnAttachedSheetEndsItOnItsParent() async throws {
        let sheet = SheetsProbeSheet()
        let parent = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered,
            defer: true)
        parent.isReleasedWhenClosed = false
        var response: NSApplication.ModalResponse?
        let window = try #require(sheet.window)
        parent.beginSheet(window) { response = $0 }
        try await SheetsSupport.wait { window.sheetParent != nil }
        sheet.finish(.OK)
        try await SheetsSupport.wait { response != nil }
        #expect(response == .OK)
        parent.close()
    }
}
