import AppKit
import Foundation
import GitaCore
import Testing

@testable import GitaUI

@Suite("Settings window") @MainActor
struct SettingsWindowControllerTests {
    @Test func selectedSidebarRowHasTranslucentFillAndContrastingText() throws {
        let sidebar = SettingsSidebarController()
        _ = sidebar.view
        let row = try #require(sidebar.tableView(sidebar.tableView, rowViewForRow: 0) as? SettingsSelectionRow)
        let cell = try #require(sidebar.tableView(sidebar.tableView, viewFor: nil, row: 0) as? NSTableCellView)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            row.appearance = NSAppearance(named: name)
            row.effectiveAppearance.performAsCurrentDrawingAppearance {
                guard let fill = SettingsSelectionRow.fillColor.usingColorSpace(.sRGB),
                    let text = cell.textField?.textColor?.usingColorSpace(.sRGB),
                    let surface = Theme.window.usingColorSpace(.sRGB),
                    let pill = surface.blended(withFraction: fill.alphaComponent, of: fill.withAlphaComponent(1))
                else {
                    Issue.record("Could not resolve sidebar colors")
                    return
                }
                #expect(fill.alphaComponent > 0 && fill.alphaComponent < 0.3)
                #expect(abs(text.brightnessComponent - pill.brightnessComponent) > 0.45)
            }
        }
    }

    @Test func preparesTheSavedPaneAndRemembersAllSidebarSelections() throws {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        recorder.defaults.set("menuBar", forKey: Preference.settingsPane.rawValue)
        let controller = SettingsWindowController(environment: recorder.environment)
        let window = controller.prepareWindow(nil)
        #expect(controller.pane == .menuBar)
        #expect(window.title == SettingsPane.menuBar.title)
        #expect(window.styleMask.contains(.resizable))
        #expect(window.contentMinSize == SettingsWindowController.minSize)
        #expect(window.frame.width == SettingsWindowController.width)
        #expect(window.contentViewController is NSSplitViewController)
        #expect(SettingsPane.allCases.count == 12)
        #expect(controller.sidebarController.displayedPanes == SettingsPane.allCases)

        for (index, pane) in SettingsPane.allCases.enumerated() {
            #expect(controller.prepareWindow(pane) === window)
            #expect(controller.pane == pane)
            #expect(window.title == pane.title)
            #expect(Preference.settingsPane.string(recorder.defaults) == pane.rawValue)
            #expect(controller.sidebarController.tableView.selectedRow == index)
        }
        // Panes are built once and reused.
        controller.select(.agents, animated: false)
        controller.select(.agents, animated: false)
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
        controller.refresh()
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

    @Test func sidebarSelectsPanesAndSupportsDeepLinking() throws {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        let controller = SettingsWindowController(environment: recorder.environment)
        let window = controller.prepareWindow(.general)
        let sidebar = controller.sidebarController
        let gitIndex = try #require(sidebar.displayedPanes.firstIndex(of: .git))
        sidebar.tableView.selectRowIndexes(IndexSet(integer: gitIndex), byExtendingSelection: false)
        #expect(controller.pane == .git)
        #expect(window.title == SettingsPane.git.title)

        controller.prepareWindow(.git, anchor: .remoteUpdates)
        #expect(controller.pane == .git)
        let remoteGroups = window.contentView?.settingsDescendants(of: SettingsGroup.self).filter {
            $0.titleLabel?.stringValue == String(localized: "Remote Updates")
        }
        #expect(remoteGroups?.count == 1)

        controller.prepareWindow(.git, anchor: .performance)
        #expect(controller.pane == .git)
        let performanceGroups = window.contentView?.settingsDescendants(of: SettingsGroup.self).filter {
            $0.titleLabel?.stringValue == String(localized: "Performance & Global Defaults")
        }
        #expect(performanceGroups?.count == 1)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
    }

    @Test func liveSearchIndexesTitlesHelpGroupsAndCardsAcrossAllPanes() throws {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        let controller = SettingsWindowController(environment: recorder.environment)
        let window = controller.prepareWindow(.general)

        // Matches help explanation text inside Git ▸ Speed up slow repositories.
        controller.search("commit-graph")
        #expect(controller.searchResult.matchingPanes.contains(.git))
        #expect(controller.pane == .git)
        let highlighted = window.contentView?.settingsDescendants(of: SettingsRow.self).filter(\.isSearchHighlighted)
        #expect(highlighted?.map(\.titleLabel.stringValue) == [String(localized: "Speed up slow repositories")])

        // Matches group title + row title inside Git ▸ Remote Updates.
        controller.search("Remote Updates ls-remote")
        #expect(controller.searchResult.matchingPanes == [.git])
        #expect((controller.searchResult.matchCounts[.git] ?? 0) >= 1)

        // Matches SettingsChoiceCard and SettingsFeatureCard titles across panes.
        controller.search("Fast-forward")
        #expect(controller.searchResult.matchingPanes.contains(.git))
        controller.search("Squash")
        #expect(controller.searchResult.matchingPanes.contains(.history))

        // Clearing search restores all panes and clears highlights.
        controller.search("")
        #expect(controller.sidebarController.displayedPanes == SettingsPane.allCases)
        let remainingHighlights =
            window.contentView?.settingsDescendants(of: SettingsRow.self).filter(\.isSearchHighlighted) ?? []
        #expect(remainingHighlights.isEmpty)

        // ⌘F routes through the window to focus the search field.
        let findEvent = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
                context: nil, characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
        #expect(window.performKeyEquivalent(with: findEvent))
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))
    }

    @Test func refreshesThePaneOnlyWhenAShownSettingChanges() async throws {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        let controller = SettingsWindowController(environment: recorder.environment)
        controller.prepareWindow(.menuBar)
        let window = try #require(controller.window)
        let switches = try #require(window.contentView?.settingsDescendants(of: AccentSwitch.self))
        let workingCount = try #require(switches.first)
        #expect(workingCount.isOn)

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

    @Test func paneMetadataHasTitlesAndValidSymbols() {
        #expect(SettingsPane.allCases.count == 12)
        for pane in SettingsPane.allCases {
            #expect(SettingsPane(rawValue: pane.rawValue) == pane)
            #expect(!pane.title.isEmpty)
            #expect(NSImage(systemSymbolName: pane.symbol, accessibilityDescription: nil) != nil)
        }
        #expect(SettingsPane(rawValue: "settings.unknown") == nil)
    }
}

extension NSView {
    /// Every subview of type `T`, depth first in subview order.
    @MainActor func settingsDescendants<T: NSView>(of _: T.Type) -> [T] {
        subviews.flatMap { view in (view as? T).map { [$0] } ?? view.settingsDescendants(of: T.self) }
    }
}
