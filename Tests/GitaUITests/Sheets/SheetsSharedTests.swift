import AppKit
import Foundation
import GitaCore
import Testing

@testable import GitaUI

@MainActor
@Suite struct SheetsLatestTaskTests {
    @Test func deliversTheResult() async throws {
        let loads = LatestTask()
        var delivered: [Result<Int, any Error>] = []
        loads.run {
            7
        } then: {
            delivered.append($0)
        }
        try await SheetsSupport.wait { !delivered.isEmpty }
        #expect(try delivered.first?.get() == 7)
    }

    @Test func deliversAFailure() async throws {
        let loads = LatestTask()
        var message: String?
        loads.run { () async throws -> Int in
            throw SheetsFailure("broken")
        } then: { result in
            if case .failure(let error) = result { message = error.localizedDescription }
        }
        try await SheetsSupport.wait { message != nil }
        #expect(message == "broken")
    }

    @Test func aNewerRunDropsTheOlderResult() async throws {
        let loads = LatestTask()
        var delivered: [String] = []
        let releaseFirst = SheetsToggle(false)
        loads.run { () async throws -> String in
            while !releaseFirst.isOn { try await Task.sleep(for: .milliseconds(2)) }
            return "first"
        } then: {
            if case .success(let value) = $0 { delivered.append(value) }
        }
        loads.run {
            "second"
        } then: {
            if case .success(let value) = $0 { delivered.append(value) }
        }
        releaseFirst.isOn = true
        try await SheetsSupport.wait { !delivered.isEmpty }
        await SheetsSupport.settle()
        #expect(delivered == ["second"])
    }

    @Test func cancelDropsTheResult() async {
        let loads = LatestTask()
        var delivered = false
        loads.run {
            1
        } then: { _ in
            delivered = true
        }
        loads.cancel()
        await SheetsSupport.settle()
        #expect(!delivered)
    }
}

@Suite struct SheetsReviewTextTests {
    @Test(arguments: [
        ("main", "main", true), ("main", "Main", false), ("caf\u{E9}", "cafe\u{301}", false), ("", "", true),
    ])
    func sameComparesBytes(left: String, right: String, expected: Bool) {
        #expect(ReviewText.same(left, right) == expected)
    }

    @Test(arguments: [
        (String(repeating: "a", count: 40), true), (String(repeating: "F", count: 64), true),
        (String(repeating: "0", count: 39), false), (String(repeating: "g", count: 40), false),
        ("", false), (String(repeating: "9", count: 41), false),
    ])
    func fullObjectIDs(value: String, expected: Bool) {
        #expect(ReviewText.isFullObjectID(value) == expected)
    }

    @Test(arguments: [
        ("refs/heads/main", "main"), ("refs/remotes/origin/main", "origin/main"), ("refs/tags/v1", "v1"),
        ("HEAD", "HEAD"), ("refs/notes/x", "refs/notes/x"),
    ])
    func shortReferences(value: String, expected: String) {
        #expect(ReviewText.shortReference(value) == expected)
    }

    @Test func messagesAreClipped() {
        let long = String(repeating: "x", count: ReviewText.errorLimit + 50)
        #expect(ReviewText.clipped(long).count == ReviewText.errorLimit)
        #expect(ReviewText.message(SheetsFailure(long)).count == ReviewText.errorLimit)
        #expect(ReviewText.message(SheetsFailure("short")) == "short")
    }
}

@Suite struct SheetsActivityTests {
    @Test func activeAndInteractive() {
        #expect(SheetActivity.built.isActive && SheetActivity.built.isInteractive)
        #expect(SheetActivity.idle.isActive && SheetActivity.idle.isInteractive)
        #expect(SheetActivity.prompting.isActive && !SheetActivity.prompting.isInteractive)
        let applying = SheetActivity.applying(refusedClose: false)
        #expect(!applying.isActive && !applying.isInteractive && applying.isApplying && !applying.refusedClose)
        #expect(SheetActivity.applying(refusedClose: true).refusedClose)
        #expect(!SheetActivity.finishing(applying: false).isActive)
        #expect(SheetActivity.finishing(applying: true).isApplying)
        #expect(!SheetActivity.finishing(applying: false).isApplying)
    }

    @Test func presentsOnceFromBuilt() {
        var activity = SheetActivity.built
        let first = activity.present()
        let second = activity.present()
        #expect(first && !second && activity == .idle)
        var closed = SheetActivity.built
        closed.finish()
        let late = closed.present()
        #expect(!late && closed == .finishing(applying: false))
    }

    @Test func promptingBlocksApplyingAndEndsIdle() {
        var activity = SheetActivity.idle
        let asked = activity.beginPrompt()
        let askedTwice = activity.beginPrompt()
        let applied = activity.beginApply()
        #expect(asked && !askedTwice && !applied && activity == .prompting)
        activity.endPrompt()
        #expect(activity == .idle)
        activity.finish()
        activity.endPrompt()
        #expect(activity.isFinishing)
    }

    @Test func applyingRefusesClosesUntilItEnds() {
        var activity = SheetActivity.idle
        let began = activity.beginApply()
        let again = activity.beginApply()
        let asked = activity.beginPrompt()
        #expect(began && !again && !asked)
        activity.refuseClose()
        #expect(activity == .applying(refusedClose: true))
        let ended = activity.endApply()
        #expect(ended && activity == .idle && !activity.refusedClose)
        let endedTwice = activity.endApply()
        activity.refuseClose()
        #expect(!endedTwice && activity == .idle)
    }

    @Test func closingUnderAMutationKeepsItRunningButUnreported() {
        var activity = SheetActivity.idle
        _ = activity.beginApply()
        activity.finish()
        #expect(activity == .finishing(applying: true) && activity.isApplying && !activity.isActive)
        activity.refuseClose()
        #expect(activity == .finishing(applying: true))
        let reported = activity.endApply()
        #expect(!reported && activity == .finishing(applying: false))
        activity.finish()
        #expect(activity == .finishing(applying: false))
    }
}

@MainActor
@Suite struct SheetsChromeTests {
    @Test func maximumSizeFitsScreenAndParent() {
        let screen = NSRect(x: 0, y: 0, width: 1_000, height: 700)
        #expect(SheetChrome.maximumSize(visible: screen, parentContent: nil) == NSSize(width: 960, height: 650))
        #expect(
            SheetChrome.maximumSize(visible: screen, parentContent: NSSize(width: 500, height: 400))
                == NSSize(width: 476, height: 376))
        #expect(SheetChrome.maximumSize(visible: nil, parentContent: nil) == NSSize(width: 1_160, height: 750))
    }

    @Test func clampMovesFramesOnScreen() {
        let visible = NSRect(x: 0, y: 0, width: 800, height: 600)
        let frame = NSRect(x: -50, y: 700, width: 200, height: 100)
        #expect(SheetChrome.clamp(frame, to: visible) == NSRect(x: 0, y: 500, width: 200, height: 100))
        #expect(SheetChrome.clamp(frame, to: nil) == frame)
        let inside = NSRect(x: 10, y: 10, width: 20, height: 20)
        #expect(SheetChrome.clamp(inside, to: visible) == inside)
    }

    @Test func showSizesTheStatusAndFlexibleRowShrinks() throws {
        UITestSupport.bootstrap()
        let chrome = SheetChrome(
            title: "Chrome", layout: SheetChrome.Layout(width: 400, spacing: 10, minimumHeight: 150),
            identifier: "chrome")
        let tall = NSView()
        chrome.add(tall, height: 5_000)
        chrome.setFlexibleRow(tall, preferred: 5_000, minimum: 40)
        let hidden = chrome.add(NSView(), height: 30)
        hidden.isHidden = true
        chrome.complete(footer: [SheetChrome.button("OK", id: "chrome.ok"), SheetChrome.spacer()])
        let maximum = chrome.maximumSize
        #expect(try #require(chrome.window.contentView).frame.height <= maximum.height)
        #expect(chrome.width == min(400, maximum.width))
        chrome.show(SheetStatus(message: "Working", isBusy: true))
        #expect(chrome.status.stringValue == "Working")
        #expect(chrome.status.textColor == .labelColor)
        chrome.show(SheetStatus(message: String(repeating: "Long error text ", count: 30), isError: true))
        #expect(chrome.status.textColor == .systemRed)
        chrome.show(SheetStatus(message: ""))
        #expect(chrome.status.stringValue.isEmpty)
        tall.isHidden = true
        chrome.fit()
        #expect(try #require(chrome.window.contentView).frame.height >= 150)
    }

    @Test func buildersConfigureControls() {
        UITestSupport.bootstrap()
        let button = SheetChrome.button("Go", id: "chrome.go", symbol: "arrow.up")
        #expect(button.accessibilityIdentifier() == "chrome.go")
        let label = SheetChrome.wrappingLabel("Text", lines: 3)
        #expect(label.maximumNumberOfLines == 3)
        let editor = NSTextView()
        let scroll = SheetChrome.plainTextEditor(editor, size: 12, label: "Editor", id: "chrome.editor")
        #expect(scroll.documentView === editor)
        #expect(!editor.isRichText && !editor.isAutomaticQuoteSubstitutionEnabled)
        #expect(SheetChrome.spacer().contentHuggingPriority(for: .horizontal) == .defaultLow)
    }
}
