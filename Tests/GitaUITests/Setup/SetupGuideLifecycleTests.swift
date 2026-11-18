import AppKit
import GitaCore
import Testing

@testable import GitaUI

@MainActor
@Suite("Setup guide lifecycle")
struct SetupGuideLifecycleTests {
    @Test func presentingStartsTheChecklistOnce() async throws {
        let harness = try SetupGuideHarness()
        harness.sandbox.recorder.answers = [.git: .ready(detail: "2.50 · Demo"), .github: .signedOut(version: "2.0")]
        let guide = harness.controller
        #expect(guide.phase == .built)
        guide.present(on: harness.parent)
        #expect(guide.phase == .presented)
        #expect(guide.checklist == nil)
        guide.show(.tools, focusSelector: false)
        try await SetupTestSupport.waitUntil("checks") { harness.sandbox.recorder.checks.count >= 3 }
        guide.present(on: harness.parent)
        let checklist = try #require(guide.checklist)
        try await SetupTestSupport.waitUntil("rendered") { checklist.phases.count == 3 }
        #expect(checklist.toolRows[.git]?.status.text.stringValue == "2.50 · Demo")
        guide.show(.history, focusSelector: true)
        guide.show(.agents, focusSelector: false)
        #expect(guide.stages.map(\.scene) == [.agents])
        guide.show(.tools, focusSelector: false)
        #expect(guide.checklist?.stopped == false)
        guide.dismiss()
        guide.dismiss()
        #expect(!guide.isOpen && guide.phase == .dismissed)
        guide.present(on: harness.parent)
        #expect(guide.phase == .dismissed, "a dismissed guide is not shown again")
    }

    @Test func activityNotificationsRefitTheWindow() throws {
        let harness = try SetupGuideHarness()
        let guide = harness.controller
        guide.present(on: harness.parent)
        guide.show(.integrations, focusSelector: false)
        NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: harness.parent)
        let note = Notification(name: NSWindow.didBecomeKeyNotification)
        guide.windowDidBecomeKey(note)
        guide.windowDidResignKey(note)
        guide.windowDidChangeOcclusionState(note)
        guide.refreshDemoActivity()
        #expect(guide.isOpen)
        guide.fitWindow()
        #expect((guide.window?.frame.width ?? 0) > 0)
        guide.cancelGuide()
        #expect(harness.cancelled == 1)
        #expect((guide.window as? SetupGuideWindow)?.onHistoryShortcut == nil)
        guide.dismiss()
    }

    @Test func theSceneAdvancesOnItsOwnWhileShownAndIdle() async throws {
        let harness = try SetupGuideHarness()
        let guide = harness.controller
        var visible = true
        guide.showsMotion = { _, _ in visible }
        guide.demoStep = .milliseconds(10)
        guide.present(on: harness.parent)
        guide.show(.agents, focusSelector: false)
        let stage = try #require(guide.stages.first)
        try await SetupTestSupport.waitUntil("a step") { stage.step > 0 }
        guide.lastInteraction = Date()
        visible = false
        try await Task.sleep(for: .milliseconds(50))
        let step = stage.step
        try await Task.sleep(for: .milliseconds(50))
        #expect(stage.step == step)
        visible = true
        guide.refreshDemoActivity()
        guide.show(.tools, focusSelector: false)
        #expect(guide.stages.isEmpty)
        guide.dismiss()
    }

    @Test func motionNeedsAVisibleKeyWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.titled], backing: .buffered,
            defer: true)
        #expect(!SetupGuideController.isMotionVisible(window: window, parent: window))
        #expect(!SetupGuideController.isMotionVisible(window: nil, parent: nil))
    }

    @Test func skipReportsCancelOnce() throws {
        let harness = try SetupGuideHarness()
        let guide = harness.controller
        guide.cancelButton.performClick(nil)
        #expect(harness.cancelled == 1)
        #expect(guide.phase == .cancelled)
        #expect(!guide.cancelButton.isEnabled)
        guide.cancelGuide()
        guide.continueGuide()
        #expect(harness.cancelled == 1)
        #expect(harness.finished.isEmpty)
        guide.present(on: harness.parent)
        #expect(guide.phase == .cancelled, "a skipped guide is never shown")
        guide.show(.ready, focusSelector: false)
        #expect(guide.card == .welcome)
    }

    @Test func closingTheWindowCancels() throws {
        let harness = try SetupGuideHarness()
        let guide = harness.controller
        let window = try #require(guide.window)
        #expect(!guide.windowShouldClose(window))
        #expect(harness.cancelled == 1)
        guide.dismiss()
        #expect(guide.windowShouldClose(window))
    }

    @Test func closeAndEscapeCancel() throws {
        let first = try SetupGuideHarness()
        first.controller.close()
        #expect(first.cancelled == 1)
        let second = try SetupGuideHarness()
        second.controller.cancelOperation(nil)
        #expect(second.cancelled == 1)
        let third = try SetupGuideHarness()
        third.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        #expect(third.cancelled == 1)
        third.controller.dismiss()
        third.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        #expect(third.cancelled == 1)
    }

    @Test func stepsMoveWithArrowKeys() throws {
        let harness = try SetupGuideHarness()
        let guide = harness.controller
        harness.step(.welcome).keyDown(with: try SetupTestSupport.key(KeyPress.downArrow))
        #expect(guide.card == .history)
        harness.step(.history).keyDown(with: try SetupTestSupport.key(KeyPress.upArrow))
        #expect(guide.card == .welcome)
        harness.step(.welcome).keyDown(with: try SetupTestSupport.key(KeyPress.rightArrow, modifiers: .shift))
        harness.step(.welcome).keyDown(with: try SetupTestSupport.key(0, characters: "a"))
        #expect(guide.card == .welcome)
    }

    @Test func historyShortcutsNeedCommand() {
        #expect(SetupGuideWindow.isHistoryShortcut(key: "+", flags: .command))
        #expect(SetupGuideWindow.isHistoryShortcut(key: "=", flags: [.command, .shift]))
        #expect(SetupGuideWindow.isHistoryShortcut(key: "d", flags: [.command, .capsLock]))
        #expect(!SetupGuideWindow.isHistoryShortcut(key: "d", flags: [.command, .shift]))
        #expect(!SetupGuideWindow.isHistoryShortcut(key: "0", flags: [.command, .option]))
        #expect(!SetupGuideWindow.isHistoryShortcut(key: "x", flags: .command))
        #expect(!SetupGuideWindow.isHistoryShortcut(key: "-", flags: []))
    }

    @Test func observationBagRemovesItsObservers() {
        let bag = SetupObservationBag()
        let center = NotificationCenter()
        let name = Notification.Name("SetupObservationBagTests")
        nonisolated(unsafe) var calls = 0
        let token = center.addObserver(forName: name, object: nil, queue: nil) { _ in calls += 1 }
        bag.add(center, token: token)
        center.post(name: name, object: nil)
        bag.removeAll()
        center.post(name: name, object: nil)
        #expect(calls == 1)
    }

    @Test func choicesReadTheModelSettings() throws {
        let sandbox = try SetupSandbox()
        Preference.useOrca.set(true, sandbox.defaults)
        Preference.useVercel.set(false, sandbox.defaults)
        sandbox.defaults.set(false, forKey: Preference.providerRefresh.rawValue)
        let model = AppModel(defaults: sandbox.defaults)
        let choices = SetupChoices(model: model)
        #expect(choices[.useOrca] && choices[.useGitHub])
        #expect(!choices[.providerRefresh] && !choices[.useVercel])
        #expect(choices[.showsHistoryDetails] == model.showsHistoryDetails)
        #expect(choices.historyZoomPercent == model.historyZoomPercent)
        #expect(Set(choices.switches.keys) == Set(SetupChoices.switchable))
        #expect(SetupGuideState.version == 2)
        var zoomed = choices
        zoomed.historyZoomPercent = 999
        #expect(zoomed.changes(from: choices) == [.historyZoomPercent(HistoryZoom.range.upperBound)])
    }
}
