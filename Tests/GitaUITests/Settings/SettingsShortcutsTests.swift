import AppKit
import Foundation
import GitaCore
import Testing

@testable import GitaUI

@Suite("Keyboard shortcuts") @MainActor
struct SettingsShortcutsTests {
    private static func key(_ characters: String, _ flags: NSEvent.ModifierFlags, code: UInt16 = 0) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    @Test func shortcutsReadWriteAndShowTheMacWay() throws {
        let shortcut = KeyShortcut("K", [.command, .shift, .function])
        #expect(shortcut.key == "k" && shortcut.display == "⇧⌘K" && shortcut.storage == "shift+cmd+k")
        #expect(KeyShortcut(storage: "shift+cmd+k") == shortcut)
        #expect(KeyShortcut(storage: "ctrl+opt+1")?.display == "⌃⌥1")
        for bad in ["", "cmd+", "shift+k", "hyper+k", "cmd+kk"] { #expect(KeyShortcut(storage: bad) == nil) }
        #expect(KeyShortcut(event: try Self.key("P", [.command, .shift], code: 35))?.display == "⇧⌘P")
        #expect(KeyShortcut(event: try Self.key("a", [])) == nil)
        let item = NSMenuItem()
        KeyShortcut.apply(shortcut, to: item)
        #expect(item.keyEquivalent == "k" && item.keyEquivalentModifierMask == [.command, .shift])
        KeyShortcut.apply(nil, to: item)
        #expect(item.keyEquivalent.isEmpty)
    }

    @Test func everyCommandHasADistinctDefaultAndAPlace() {
        let defaults = ShortcutCommand.allCases.map(\.defaultShortcut)
        #expect(Set(defaults).count == defaults.count)
        #expect(ShortcutCommand.allCommits.defaultShortcut.display == "⌥⌘1")
        #expect(ShortcutCommand.workflows.defaultShortcut.display == "⌥⌘6")
        #expect(ShortcutCommand.fileTreeTab.defaultShortcut.display == "⌃⌘3")
        #expect(ShortcutCommand.commandPalette.defaultShortcut.display == "⌘K")
        #expect(ShortcutCommand.switchBranch.defaultShortcut.display == "⇧⌘K")
        for command in ShortcutCommand.allCases { #expect(!command.title.isEmpty) }
        #expect(Set(ShortcutCommand.allCases.map(\.group)) == Set(ShortcutCommand.Group.allCases))
        #expect(ShortcutCommand.page(.pullRequests) == .pullRequests && ShortcutCommand.page(.agents) == nil)
        #expect(ShortcutCommand.push.toolTip.hasPrefix(ShortcutCommand.push.title))
    }

    @Test func aShortcutTakenByAnotherCommandLeavesIt() throws {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        let defaults = recorder.defaults
        let taken = ShortcutCommand.fetch.defaultShortcut
        ShortcutStore.set(taken, for: .push, defaults)
        #expect(ShortcutStore.shortcut(.push, defaults) == taken)
        #expect(ShortcutStore.shortcut(.fetch, defaults) == nil)
        #expect(ShortcutStore.command(using: taken, defaults) == .push)
        ShortcutStore.set(nil, for: .pull, defaults)
        #expect(ShortcutStore.shortcut(.pull, defaults) == nil)
        let menu = NSMenu()
        let item = NSMenuItem(title: "Push", action: nil, keyEquivalent: "")
        item.identifier = ShortcutCommand.push.menuIdentifier
        let submenu = NSMenu()
        submenu.addItem(item)
        let submenuItem = NSMenuItem(title: "Repository", action: nil, keyEquivalent: "")
        submenuItem.submenu = submenu
        menu.addItem(submenuItem)
        ShortcutStore.keepApplied(to: menu, defaults)
        #expect(item.keyEquivalent == "f")
        ShortcutStore.resetAll(defaults)
        #expect(item.keyEquivalent == "p")
        #expect(ShortcutStore.shortcut(.fetch, defaults) == ShortcutCommand.fetch.defaultShortcut)
    }

    @Test func theRecorderTakesAShortcutClearsAndCancels() throws {
        let recorder = ShortcutRecorder(accessibility: "Fetch")
        var recorded: [KeyShortcut?] = []
        var accepts = true
        recorder.onRecord = {
            recorded.append($0)
            return accepts
        }
        recorder.startRecording()
        #expect(recorder.isRecording)
        #expect(recorder.performKeyEquivalent(with: try Self.key("j", [.command, .option])))
        #expect(recorded.last == KeyShortcut("j", [.command, .option]))
        #expect(recorder.shortcut?.display == "⌥⌘J" && !recorder.isRecording)
        recorder.startRecording()
        recorder.keyDown(with: try Self.key("\u{7F}", [], code: KeyPress.delete))
        #expect(recorder.shortcut == nil)
        recorder.startRecording()
        recorder.keyDown(with: try Self.key("\u{1B}", [], code: KeyPress.escape))
        #expect(!recorder.isRecording && recorded.count == 2)
        recorder.startRecording()
        recorder.record(try Self.key("x", []))
        #expect(recorder.isRecording)
        accepts = false
        recorder.record(try Self.key("x", .command))
        #expect(recorder.shortcut == nil)
        recorder.keyDown(with: try Self.key(" ", [], code: KeyPress.space))
        #expect(recorder.isRecording)
        #expect(recorder.resignFirstResponder() && !recorder.isRecording)
        #expect(!recorder.performKeyEquivalent(with: try Self.key("q", .command)))
        #expect(recorder.accessibilityPerformPress())
        let image = NSImage(size: recorder.intrinsicContentSize)
        image.lockFocus()
        recorder.draw(recorder.bounds)
        recorder.stopRecordingForTest()
        recorder.draw(recorder.bounds)
        image.unlockFocus()
    }

    @Test func thePaneRecordsRefusesMenuShortcutsAndRestores() throws {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        let pane = ShortcutsSettingsPane(environment: recorder.environment)
        let menu = NSMenu()
        let file = NSMenu()
        file.addItem(NSMenuItem(title: "Open Repository…", action: nil, keyEquivalent: "o"))
        file.addItem(NSMenuItem(title: "Activity", action: nil, keyEquivalent: "A"))
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        fileItem.submenu = file
        menu.addItem(fileItem)
        pane.menu = { menu }
        pane.refresh()
        #expect(pane.recorders.count == ShortcutCommand.allCases.count)
        #expect(pane.recorders[.push]?.shortcut?.display == "⇧⌘P")
        #expect(!pane.record(KeyShortcut("o", .command), for: .push))
        #expect(pane.note.stringValue.contains("Open Repository…"))
        #expect(!pane.record(KeyShortcut("a", [.command, .shift]), for: .push))
        #expect(pane.record(ShortcutCommand.fetch.defaultShortcut, for: .push))
        #expect(pane.note.stringValue.contains(ShortcutCommand.fetch.title))
        #expect(pane.recorders[.fetch]?.shortcut == nil)
        #expect(pane.record(nil, for: .push))
        #expect(pane.note.stringValue.isEmpty)
        let restore = try SetupTestSupport.button("settings.shortcuts.restore", in: pane.view)
        restore.performClick(nil)
        #expect(pane.recorders[.fetch]?.shortcut == ShortcutCommand.fetch.defaultShortcut)
        #expect(ShortcutsSettingsPane.menuTitle(using: KeyShortcut("z", .command), in: nil) == nil)
        #expect(SettingsPane.shortcuts.title == String(localized: "Shortcuts"))
    }
}

extension ShortcutRecorder {
    /// Leaves recording without a key, for drawing both looks.
    func stopRecordingForTest() { _ = resignFirstResponder() }
}
