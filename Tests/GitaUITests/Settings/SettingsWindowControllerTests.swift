import AppKit
import Foundation
import GitaCore
import Testing

@testable import GitaUI

@Suite("Settings window") @MainActor
struct SettingsWindowControllerTests {
    @Test func preparesTheSavedPaneAndRemembersEverySelection() throws {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        recorder.defaults.set("menuBar", forKey: Preference.settingsPane.rawValue)
        let controller = SettingsWindowController(environment: recorder.environment)
        let window = controller.prepareWindow(nil)
        #expect(controller.pane == .menuBar)
        #expect(window.title == SettingsPane.menuBar.title)
        #expect(window.frame.width == SettingsWindowController.width)
        #expect(window.contentView is SettingsBackgroundView)

        for pane in SettingsPane.allCases {
            #expect(controller.prepareWindow(pane) === window)
            #expect(controller.pane == pane)
            #expect(window.title == pane.title)
            #expect(Preference.settingsPane.string(recorder.defaults) == pane.rawValue)
            #expect(window.contentView?.subviews.count == 1)
        }
        // Panes are built once and reused.
        controller.select(.agents, animated: false)
        controller.select(.agents, animated: false)
        #expect(window.contentView?.subviews.count == 1)
        #expect(recorder.reviewAgentRefreshes >= 2)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
    }

    @Test func unknownSavedPaneFallsBackToGeneral() {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        recorder.defaults.set("nonsense", forKey: Preference.settingsPane.rawValue)
        let controller = SettingsWindowController(environment: recorder.environment)
        controller.prepareWindow(nil)
        #expect(controller.pane == .general)
        controller.refresh() // not on screen: nothing to re-read
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
    }

    @Test func selectWithoutWindowDoesNothing() {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        let controller = SettingsWindowController(environment: recorder.environment)
        controller.select(.git, animated: false)
        #expect(controller.pane == .general)
        #expect(controller.window == nil)
    }

    @Test func toolbarListsEveryPaneAndSelectsThroughItsItems() throws {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        let controller = SettingsWindowController(environment: recorder.environment)
        let window = controller.prepareWindow(.general)
        let toolbar = try #require(window.toolbar)
        let identifiers = SettingsPane.allCases.map(\.itemIdentifier)
        #expect(controller.toolbarAllowedItemIdentifiers(toolbar) == identifiers)
        #expect(controller.toolbarDefaultItemIdentifiers(toolbar) == identifiers)
        #expect(controller.toolbarSelectableItemIdentifiers(toolbar) == identifiers)
        #expect(
            controller.toolbar(
                toolbar, itemForItemIdentifier: NSToolbarItem.Identifier("other"), willBeInsertedIntoToolbar: true)
                == nil)

        let item = try #require(
            controller.toolbar(
                toolbar, itemForItemIdentifier: SettingsPane.git.itemIdentifier, willBeInsertedIntoToolbar: true))
        #expect(item.label == "Git")
        #expect(item.image != nil)
        let action = try #require(item.action)
        #expect(NSApp.sendAction(action, to: item.target, from: item))
        #expect(controller.pane == .git)
        // Choosing the pane already shown changes nothing.
        #expect(NSApp.sendAction(action, to: item.target, from: item))
        #expect(controller.pane == .git)
    }

    @Test func refreshesThePaneOnlyWhenAShownSettingChanges() async throws {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        let controller = SettingsWindowController(environment: recorder.environment)
        controller.prepareWindow(.menuBar)
        let window = try #require(controller.window)
        let pane = try #require(window.contentView?.subviews.first)
        let switches = pane.settingsDescendants(of: AccentSwitch.self)
        let workingCount = try #require(switches.first)
        #expect(workingCount.isOn)

        // Window state does not refresh; a shown setting written elsewhere does, once per burst.
        recorder.defaults.set(["a": 1], forKey: Preference.authorColors.rawValue)
        controller.settingsMayHaveChanged()
        recorder.defaults.set(false, forKey: Preference.menuBarShowsWorkingCount.rawValue)
        controller.settingsMayHaveChanged()
        controller.settingsMayHaveChanged()
        try await SettingsWait.until { !workingCount.isOn }
        #expect(!workingCount.isOn)

        recorder.defaults.set(true, forKey: Preference.menuBarShowsWorkingCount.rawValue)
        controller.applicationDidBecomeActive()
        try await SettingsWait.until { workingCount.isOn }
        #expect(workingCount.isOn)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
    }

    @Test func fittedFrameKeepsTheTopEdgeInsideTheScreen() {
        let current = NSRect(x: 900, y: 500, width: 680, height: 300)
        let free = SettingsWindowController.fittedFrame(current: current, height: 400, visible: nil)
        #expect(free == NSRect(x: 900, y: 400, width: 680, height: 400))
        let screen = NSRect(x: 0, y: 450, width: 1_200, height: 800)
        let clamped = SettingsWindowController.fittedFrame(current: current, height: 400, visible: screen)
        #expect(clamped == NSRect(x: 520, y: 450, width: 680, height: 400))
        let left = SettingsWindowController.fittedFrame(
            current: NSRect(x: -50, y: 500, width: 680, height: 300), height: 200, visible: screen)
        #expect(left.minX == 0)
        #expect(left.maxY == 800)
    }

    @Test func paneMetadataRoundTrips() {
        for pane in SettingsPane.allCases {
            #expect(SettingsPane(itemIdentifier: pane.itemIdentifier) == pane)
            #expect(!pane.title.isEmpty)
            #expect(NSImage(systemSymbolName: pane.symbol, accessibilityDescription: nil) != nil)
        }
        #expect(SettingsPane(itemIdentifier: NSToolbarItem.Identifier("settings.unknown")) == nil)
    }
}

extension NSView {
    /// Every subview of type `T`, depth first in subview order.
    @MainActor func settingsDescendants<T: NSView>(of _: T.Type) -> [T] {
        subviews.flatMap { view in (view as? T).map { [$0] } ?? view.settingsDescendants(of: T.self) }
    }
}
