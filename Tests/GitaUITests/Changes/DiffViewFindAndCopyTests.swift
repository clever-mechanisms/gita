import AppKit
import Foundation
import GitaCore
import Testing

@testable import GitaUI

@MainActor
@Suite(.serialized)
struct DiffViewFindAndCopyTests {
    private static let sampleDiff = [
        "diff --git a/Sources/App.swift b/Sources/App.swift",
        "index 1111111..2222222 100644",
        "--- a/Sources/App.swift",
        "+++ b/Sources/App.swift",
        "@@ -1,4 +1,4 @@ struct App",
        " let title = \"Alpha\"",
        "-let mode = \"oldAlpha\"",
        "+let mode = \"newAlpha\"",
        " let tail = 1",
        "",
    ].joined(separator: "\n")

    private func waitUntil(_ message: String, until check: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !check() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for \(message)")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func diffFindCounterTextAndMatcherOffsets() {
        #expect(DiffFind.closed.counterText.isEmpty)
        #expect(!DiffFind.closed.isOpen)

        let task = Task<Void, Never> {}
        task.cancel()
        #expect(DiffFind.searching(task).counterText == "Searching…")
        #expect(DiffFind.searching(task).isOpen)

        #expect(DiffFind.open(query: "", matches: [], current: 0).counterText.isEmpty)
        #expect(DiffFind.open(query: "missing", matches: [], current: 0).counterText == "No matches")
        #expect(DiffFind.open(query: "alpha", matches: [2, 5, 9], current: 2).counterText == "3 of 3")

        let lines = [
            DiffLine(text: "+😀 alpha ALPHA", old: "", new: "1", kind: "+", hunkIndex: 0),
            DiffLine(text: " alpha", old: "2", new: "2", kind: " ", hunkIndex: 0),
            DiffLine(text: "-other", old: "3", new: "", kind: "-", hunkIndex: 0),
        ]
        let matched = DiffFindMatcher.match(query: "alpha", in: lines, isBlob: false)
        #expect(matched.rows == [0, 0, 1])
        // Leading '+' is skipped (+1), '😀' is 2 UTF-16 units + ' ' (1) = offset 4 for first "alpha"
        #expect(matched.rangesByRow[0] == [4..<9, 10..<15])
        #expect(matched.rangesByRow[1] == [1..<6])

        // Searching "+" does not match the diff marker prefix
        let plusMatches = DiffFindMatcher.match(query: "+", in: lines, isBlob: false)
        #expect(plusMatches.rows.isEmpty)
    }

    @Test func findBarOpensSearchesNavigatesAndClosesViaShortcuts() async throws {
        UITestSupport.bootstrap()
        let diffView = DiffView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 320), styleMask: [.titled],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = diffView
        diffView.update(Self.sampleDiff, loading: false, path: "Sources/App.swift")
        try await waitUntil("parsed diff") { !diffView.currentLines.isEmpty }

        window.makeFirstResponder(diffView.table)
        let cmdF = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "f",
                charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
        #expect(diffView.handleFindKeyEquivalent(cmdF))
        #expect(diffView.findState.isOpen)
        #expect(!diffView.findBar.isHidden)
        #expect(diffView.findBarHeight.constant == DiffFindBar.height)

        diffView.findBar.field.stringValue = "alpha"
        diffView.updateFindQuery("alpha")
        try await waitUntil("find matches") {
            if case .open(_, let matches, _) = diffView.findState { return matches.count == 3 }
            return false
        }
        #expect(diffView.findBar.countLabel.stringValue == "1 of 3")

        let cmdG = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "g",
                charactersIgnoringModifiers: "g", isARepeat: false, keyCode: 5))
        #expect(diffView.handleFindKeyEquivalent(cmdG))
        #expect(diffView.findBar.countLabel.stringValue == "2 of 3")

        let shiftCmdG = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "G",
                charactersIgnoringModifiers: "g", isARepeat: false, keyCode: 5))
        #expect(diffView.handleFindKeyEquivalent(shiftCmdG))
        #expect(diffView.findBar.countLabel.stringValue == "1 of 3")
        #expect(diffView.handleFindKeyEquivalent(shiftCmdG))
        #expect(diffView.findBar.countLabel.stringValue == "3 of 3")

        let esc = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\u{1B}",
                charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53))
        #expect(diffView.handleFindKeyEquivalent(esc))
        #expect(!diffView.findState.isOpen)
        #expect(diffView.findBar.isHidden)
        #expect(diffView.findBarHeight.constant == 0)
        window.close()
    }

    @Test func multiRowCopyContextMenuAndDoubleClickOpenInEditor() async throws {
        UITestSupport.bootstrap()
        let diffView = DiffView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
        diffView.update(Self.sampleDiff, loading: false, path: "Sources/App.swift")
        try await waitUntil("parsed diff") { !diffView.currentLines.isEmpty }

        var copied: [String] = []
        diffView.copyText = { copied.append($0) }

        let firstCodeRow = try #require(diffView.currentLines.firstIndex { $0.kind == "-" })
        let rows = IndexSet([firstCodeRow, firstCodeRow + 1])
        #expect(
            !diffView.table.validateUserInterfaceItem(
                NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")))
        diffView.table.selectRowIndexes(rows, byExtendingSelection: false)
        #expect(
            diffView.table.validateUserInterfaceItem(
                NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")))
        let cmdC = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
                windowNumber: 0, context: nil, characters: "c",
                charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
        #expect(diffView.table.performKeyEquivalent(with: cmdC))
        #expect(copied == ["let mode = \"oldAlpha\"\nlet mode = \"newAlpha\""])

        let menu = try #require(diffView.contextMenu(for: rows))
        #expect(menu.items.map(\.title).contains("Copy Lines"))
        #expect(menu.items.map(\.title).contains("Copy as Patch"))
        #expect(menu.items.map(\.title).contains("Open in Editor at Line"))

        copied.removeAll()
        menu.item(titled: "Copy as Patch")?.perform()
        #expect(copied == ["-let mode = \"oldAlpha\"\n+let mode = \"newAlpha\""])

        var openedLines: [Int?] = []
        diffView.onOpenInEditor = { openedLines.append($0) }
        menu.item(titled: "Open in Editor at Line")?.perform()
        #expect(openedLines == [2])
        diffView.doubleClickedRow()
        #expect(openedLines == [2])
    }

    @Test func codeFontSizeAndTabWidthAreRespected() {
        let suite = "GitaUITests.codeFont." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("Failed to create defaults suite")
            return
        }
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        #expect(CodeFont.diffSize(defaults) == 11)
        #expect(CodeFont.tabWidth(defaults) == 4)

        defaults.set(40.0, forKey: "codeFontSize")
        #expect(CodeFont.diffSize(defaults) == 24)
        defaults.set(4.0, forKey: "codeFontSize")
        #expect(CodeFont.diffSize(defaults) == 9)
        defaults.set(15.0, forKey: "codeFontSize")
        #expect(CodeFont.diffSize(defaults) == 15)

        defaults.set(8, forKey: "tabWidth")
        #expect(CodeFont.tabWidth(defaults) == 8)
        defaults.set(2, forKey: "diffTabWidth")
        #expect(CodeFont.tabWidth(defaults) == 2)
        defaults.set(5, forKey: "diffTabWidth")
        #expect(CodeFont.tabWidth(defaults) == 8)

        #expect(DiffCell.shown("+\tfoo", tabWidth: 2) == "+  foo")
        let mapped = DiffCell.mapRanges([2..<5], in: "+\tfoo", tabWidth: 2)
        #expect(mapped == [3..<6])
    }
}
