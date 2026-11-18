import AppKit
import GitaCore
import Testing

@testable import GitaUI

/// What the guide reported through its callbacks.
@MainActor
final class SetupGuideReports {
    var finished: [SetupChoices] = []
    var cancelled = 0
}

/// A guide built on a recording checklist, with what Finish and Cancel reported.
@MainActor
final class SetupGuideHarness {
    let sandbox: SetupSandbox
    let reports = SetupGuideReports()
    let controller: SetupGuideController
    let parent: NSWindow
    var finished: [SetupChoices] { reports.finished }
    var cancelled: Int { reports.cancelled }

    init(choices: SetupChoices = SetupGuideHarness.choices, firstRun: Bool = true) throws {
        UITestSupport.bootstrap()
        let sandbox = try SetupSandbox()
        self.sandbox = sandbox
        parent = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_100, height: 760), styleMask: [.titled, .closable],
            backing: .buffered, defer: true)
        parent.isReleasedWhenClosed = false
        let reports = reports
        controller = SetupGuideController(
            choices: choices, firstRun: firstRun, onFinish: { reports.finished.append($0) },
            onCancel: { reports.cancelled += 1 }, checklist: sandbox.environment())
    }

    /// Everything on but the commit details and Orca.
    static let choices: SetupChoices = {
        var choices = SetupChoices(historyZoomPercent: 100, switches: [:])
        for preference in SetupChoices.switchable { choices[preference] = true }
        choices[.showsHistoryDetails] = false
        choices[.useOrca] = false
        return choices
    }()

    func step(_ card: SetupGuideCard) -> SetupCardButton { controller.cardButtons[card.rawValue] }
}

@MainActor
@Suite("Setup guide controller")
struct SetupGuideControllerTests {
    @Test func startsOnTheWelcomeStep() throws {
        let harness = try SetupGuideHarness()
        let guide = harness.controller
        #expect(guide.card == .welcome)
        #expect(guide.heading.stringValue == SetupGuideCard.welcome.heading)
        #expect(guide.subtitle.stringValue == SetupGuideCard.welcome.subtitle)
        #expect(guide.position.stringValue.contains("1"))
        #expect(guide.stages.map(\.scene) == [.history, .pullRequests, .agents, .menuBar])
        #expect(guide.options?.tiles.isEmpty == true)
        #expect(guide.checklist == nil)
        #expect(!guide.backButton.isEnabled)
        #expect(guide.cancelButton.title == String(localized: "Skip"))
        #expect(harness.step(.welcome).isCurrent && !harness.step(.history).isCurrent)
        #expect(guide.window?.title == String(localized: "Setup Guide"))
        guide.dismiss()
    }

    @Test func notFirstRunOffersCancelAndClampsTheZoom() throws {
        var choices = SetupGuideHarness.choices
        choices.historyZoomPercent = 400
        let harness = try SetupGuideHarness(choices: choices, firstRun: false)
        #expect(harness.controller.cancelButton.title == String(localized: "Cancel"))
        #expect(harness.controller.draft.historyZoomPercent == HistoryZoom.range.upperBound)
    }

    @Test func continueWalksEveryStepThenFinishes() throws {
        let harness = try SetupGuideHarness()
        let guide = harness.controller
        for card in SetupGuideCard.allCases.dropFirst() {
            guide.nextButton.performClick(nil)
            #expect(guide.card == card)
            #expect((guide.checklist != nil) == (card == .tools))
            #expect(guide.stages.first?.scene == card.pageScene ?? guide.options?.stages.first?.scene)
            #expect(guide.stages.isEmpty == (card == .tools))
            #expect(harness.step(card).isCurrent)
        }
        #expect(guide.nextButton.title == String(localized: "Finish"))
        #expect(guide.nextButton.accessibilityIdentifier() == "setup.finish")
        guide.nextButton.performClick(nil)
        #expect(harness.finished == [SetupGuideHarness.choices])
        #expect(!guide.isOpen && guide.phase == .finished)
        #expect(!guide.nextButton.isEnabled && !harness.step(.welcome).isEnabled)
        guide.continueGuide()
        #expect(harness.finished.count == 1)
    }

    @Test func backAndStepsMoveBetweenCards() throws {
        let harness = try SetupGuideHarness()
        let guide = harness.controller
        harness.step(.agents).performClick(nil)
        #expect(guide.card == .agents)
        #expect(harness.step(.agents).isCurrent && !harness.step(.welcome).isCurrent)
        guide.backButton.performClick(nil)
        #expect(guide.card == .integrations)
        harness.step(.welcome).performClick(nil)
        guide.back()
        #expect(guide.card == .welcome)
        guide.moveCard(10, focusSelector: false)
        #expect(guide.card == .welcome)
    }

    @Test func historyZoomAndDetailsChangeTheDraft() throws {
        let harness = try SetupGuideHarness()
        let guide = harness.controller
        guide.reduceZoom()
        #expect(guide.draft.historyZoomPercent == 100)
        harness.step(.history).performClick(nil)
        guide.zoomIn.performClick(nil)
        guide.zoomIn.performClick(nil)
        #expect(guide.draft.historyZoomPercent == 120)
        #expect(guide.zoomValue.title.contains("120"))
        #expect(guide.stages.map(\.scene) == [.details, .zoom, .collapse, .squash])
        #expect(guide.stages.allSatisfy { $0.choices.historyZoomPercent == 120 })
        guide.zoomOut.performClick(nil)
        #expect(guide.draft.historyZoomPercent == 110)
        guide.zoomValue.performClick(nil)
        #expect(guide.draft.historyZoomPercent == 100)
        for _ in 0..<5 { guide.reduceZoom() }
        #expect(guide.draft.historyZoomPercent == HistoryZoom.range.lowerBound)
        #expect(!guide.zoomOut.isEnabled)
        guide.toggleDetails()
        #expect(guide.draft[.showsHistoryDetails])
        #expect(guide.options?.tiles[.showsHistoryDetails]?.toggle?.isOn == true)
    }

    @Test func tileSwitchesDraftTheirSettingAndTheSceneFollows() throws {
        let harness = try SetupGuideHarness()
        let guide = harness.controller
        guide.show(.integrations, focusSelector: false)
        let vercel = try #require(guide.options?.tiles[.useVercel]?.toggle)
        #expect(vercel.isOn)
        _ = vercel.accessibilityPerformPress()
        #expect(!guide.draft[.useVercel])
        #expect(guide.stages.first?.choices[.useVercel] == false)
        #expect(guide.lastInteraction > .distantPast)
        guide.show(.agents, focusSelector: false)
        guide.setChoice(.useAgents, false)
        let claude = try #require(guide.options?.tiles[AgentTool.claudeCode.detectionPreference])
        #expect(claude.toggle?.isEnabled == false)
        guide.show(.ready, focusSelector: false)
        guide.continueGuide()
        let finished = try #require(harness.finished.first)
        #expect(!finished[.useVercel] && !finished[.useAgents])
        #expect(
            finished.changes(from: SetupGuideHarness.choices) == [
                .setting(.useVercel, false), .setting(.useAgents, false),
            ])
        guide.setChoice(.useGitHub, false)
        #expect(guide.draft[.useGitHub])
    }

    @Test func historyShortcutsWorkOnTheHistoryStepOnly() throws {
        let harness = try SetupGuideHarness()
        let guide = harness.controller
        #expect(!guide.handleHistoryShortcut("+"))
        guide.toggleDetails()
        #expect(!guide.draft[.showsHistoryDetails])
        guide.show(.history, focusSelector: false)
        #expect(guide.handleHistoryShortcut("+"))
        #expect(guide.handleHistoryShortcut("="))
        #expect(guide.draft.historyZoomPercent == 120)
        #expect(guide.handleHistoryShortcut("-"))
        #expect(guide.draft.historyZoomPercent == 110)
        #expect(guide.handleHistoryShortcut("0"))
        #expect(guide.draft.historyZoomPercent == 100)
        #expect(guide.handleHistoryShortcut("d"))
        #expect(guide.draft[.showsHistoryDetails])
        #expect(!guide.handleHistoryShortcut("x"))
    }

    @Test func theWindowRoutesCommandKeysToTheGuide() throws {
        let harness = try SetupGuideHarness()
        let guide = harness.controller
        let window = try #require(guide.window as? SetupGuideWindow)
        guide.show(.history, focusSelector: false)
        let zoomIn = try SetupTestSupport.key(24, characters: "=", modifiers: .command)
        #expect(window.performKeyEquivalent(with: zoomIn))
        #expect(guide.draft.historyZoomPercent == 110)
        let plain = try SetupTestSupport.key(2, characters: "d")
        #expect(!window.performKeyEquivalent(with: plain))
        #expect(!guide.draft[.showsHistoryDetails])
    }

    @Test func theRailTicksTheStepsBehind() throws {
        let harness = try SetupGuideHarness()
        harness.controller.show(.agents, focusSelector: false)
        #expect(harness.step(.history).contentTintColor == Theme.success)
        #expect(harness.step(.agents).contentTintColor == Theme.accentText)
        #expect(harness.step(.ready).contentTintColor == Theme.secondaryText)
        #expect(harness.step(.agents).accessibilityValue() as? String == String(localized: "current"))
        let image = NSImage(size: NSSize(width: 120, height: 32))
        image.lockFocusFlipped(true)
        harness.step(.agents).draw(NSRect(x: 0, y: 0, width: 120, height: 32))
        image.unlockFocus()
        #expect(SetupStepCell().drawingRect(forBounds: NSRect(x: 0, y: 0, width: 100, height: 20)).minX >= 10)
    }
}
