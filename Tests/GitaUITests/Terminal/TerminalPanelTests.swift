import AppKit
import Foundation
import Testing

@testable import GitaCore
@testable import GitaUI

/// The terminal panel at the bottom of the main window, its terminals backed by recorded programs.
@MainActor
@Suite("Built-in terminal panel")
struct TerminalPanelTests {
    @MainActor
    private final class Fixture {
        let panel = TerminalPanelView()
        var harnesses: [SessionHarness] = []
        var shown: [Bool] = []

        init(directory: URL? = URL(fileURLWithPath: "/tmp/repo")) {
            panel.makeTerminal = { [weak self] folder, launch in
                let harness = SessionHarness(launch: launch, folder: folder)
                self?.harnesses.append(harness)
                return TerminalView(session: harness.session, page: nil)
            }
            panel.currentDirectory = { directory }
            panel.onVisibilityChange = { [weak self] in self?.shown.append($0) }
        }
    }

    private func titles(_ panel: TerminalPanelView) -> [String] {
        SetupTestSupport.views(PartsButton.self, in: panel).compactMap { $0.accessibilityLabel() }
    }

    @Test func terminalsOpenAsTabsAndClosingOneEndsItsProgram() throws {
        let fixture = Fixture()
        let panel = fixture.panel
        let repo = URL(fileURLWithPath: "/tmp/repo")
        let first = panel.open(repo)
        let review = panel.open(repo, launch: .script(URL(fileURLWithPath: "/tmp/review.command")))
        #expect(fixture.shown == [true, true])
        #expect(panel.entries.map(\.title) == ["repo", String(localized: "Review · repo")])
        #expect(panel.selectedID == review.id)
        #expect(first.terminal.isHidden && !review.terminal.isHidden)
        #expect(titles(panel).contains(String(localized: "Close \("repo")")))
        fixture.harnesses.forEach { $0.ready() }
        let programs = try fixture.harnesses.map { try #require($0.processes.first) }

        // The program names its tab.
        review.terminal.session.onTitle?("Claude Code")
        review.terminal.session.onTitle?("")
        #expect(panel.entries.last?.title == "Claude Code")

        panel.select(first.id)
        #expect(!first.terminal.isHidden && review.terminal.isHidden)
        panel.close(review.id)
        #expect(programs[1].terminated, "closing the tab hangs its program up")
        #expect(review.terminal.session.state == .closed)
        #expect(review.terminal.superview == nil)
        #expect(!programs[0].terminated)
        #expect(panel.selectedID == first.id)
        panel.close(first.id)
        #expect(programs[0].terminated)
        #expect(panel.entries.isEmpty && panel.selectedID == nil)
        #expect(fixture.shown.last == false, "the panel hides with its last tab")
        panel.close(first.id) // already closed: nothing happens
        panel.select(first.id)
        #expect(panel.selectedID == nil)
    }

    @Test func closingTheSelectedTabSelectsTheNextAndCloseAllEndsEveryProgram() throws {
        let fixture = Fixture()
        let panel = fixture.panel
        let repo = URL(fileURLWithPath: "/tmp/repo")
        let entries = (0..<3).map { _ in panel.open(repo) }
        fixture.harnesses.forEach { $0.ready() }
        panel.select(entries[1].id)
        panel.close(entries[1].id)
        #expect(panel.selectedID == entries[2].id)
        panel.close(entries[0].id)
        #expect(panel.selectedID == entries[2].id)
        panel.open(repo)
        fixture.harnesses.last?.ready()
        panel.closeAll()
        #expect(panel.entries.isEmpty)
        #expect(fixture.harnesses.allSatisfy { $0.processes.allSatisfy(\.terminated) })
        #expect(fixture.harnesses.allSatisfy { $0.session.state == .closed })
    }

    @Test func plusOpensAShellInTheCurrentRepositoryAndHideHides() {
        let fixture = Fixture()
        fixture.panel.openShell()
        #expect(fixture.panel.selected?.terminal.session.directory == URL(fileURLWithPath: "/tmp/repo"))
        let buttons = SetupTestSupport.views(PartsButton.self, in: fixture.panel)
        buttons.first { $0.accessibilityLabel() == String(localized: "New Terminal") }?.onClick?()
        #expect(fixture.panel.entries.count == 2)
        buttons.first { $0.accessibilityLabel() == String(localized: "Hide Terminal") }?.onClick?()
        #expect(fixture.shown.last == false)
        #expect(fixture.panel.entries.count == 2, "hiding keeps the terminals running")
        let tabs = SetupTestSupport.views(PartsButton.self, in: fixture.panel)
        tabs.first { $0.accessibilityLabel() == String(localized: "Close \("repo")") }?.onClick?()
        #expect(fixture.panel.entries.count == 1)
        tabs.first { $0.accessibilityLabel() == "repo" }?.onClick?()

        let nowhere = Fixture(directory: nil)
        nowhere.panel.openShell()
        #expect(nowhere.panel.entries.isEmpty, "no repository: nothing to open")
    }

    @Test func theHeightIsAShareOfTheWindowKeptWithinBounds() {
        #expect(TerminalPanelHeight.defaultShare == 0.3)
        #expect(TerminalPanelHeight.height(share: 0.3, in: 1_000) == 300)
        #expect(TerminalPanelHeight.height(share: 0.02, in: 1_000) == 100, "at least 10%")
        #expect(TerminalPanelHeight.height(share: 0.95, in: 1_000) == 800, "the repository keeps 200 points")
        #expect(TerminalPanelHeight.height(share: .nan, in: 1_000) == 300)
        #expect(TerminalPanelHeight.height(share: 0.3, in: 150) == TerminalPanelView.minimumHeight)
    }

    @Test func onlyADragOfTheDividerIsRemembered() throws {
        let sandbox = try AgentsSandbox("Terminal")
        let fixture = Fixture()
        let panel = fixture.panel
        panel.defaults = sandbox.defaults
        let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: 800, height: 1_000))
        split.addArrangedSubview(NSView())
        split.addArrangedSubview(panel)
        panel.frame.size.height = 450
        let resized = NSSplitView.didResizeSubviewsNotification
        panel.splitViewDidResizeSubviews(Notification(name: resized, object: split))
        #expect(Preference.terminalPanelShare.double(sandbox.defaults) == 0.3, "a window resize is not remembered")
        let dragged = Notification(name: resized, object: split, userInfo: ["NSSplitViewDividerIndex": 0])
        panel.splitViewDidResizeSubviews(dragged)
        #expect(Preference.terminalPanelShare.double(sandbox.defaults) == 0.45)
        panel.isHidden = true
        panel.frame.size.height = 100
        panel.splitViewDidResizeSubviews(dragged)
        #expect(Preference.terminalPanelShare.double(sandbox.defaults) == 0.45, "a hidden panel remembers nothing")
    }
}
