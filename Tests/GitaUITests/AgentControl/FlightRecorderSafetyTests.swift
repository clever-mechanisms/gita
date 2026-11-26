import AppKit
import GitaCore
import Testing

@testable import GitaUI

@Suite @MainActor
struct AgentControlFlightRecorderSafetyTests {
    private func loaded(_ presenter: FlightRecorderPresenter) async throws {
        try #require(
            await SharedFixtures.waitUntil(seconds: 20) {
                if case .loaded = presenter.state { return true }
                return false
            })
    }

    @Test func decliningEveryDestructiveActionPreservesTheWorkingTreeAndHistory() async throws {
        UITestSupport.bootstrap()
        let repo = try TemporaryRepository()
        try repo.commit("file", "base\n", message: "base")
        let service = FlightRecorderService()
        await service.setEnabled(true, for: repo.url)
        let saved = try await service.captureSnapshot(in: repo.url)
        try repo.write("file", "working\n")
        let presenter = FlightRecorderPresenter(service: service, repositoryRoot: repo.url)
        let controller = AgentFlightRecorderViewController(presenter: presenter)
        let window = UITestSupport.host(controller)
        defer { window.close() }
        presenter.load()
        try await loaded(presenter)
        presenter.selectComparison(toSnapshotID: nil)
        try await loaded(presenter)
        var titles: [String] = []
        var messages: [String] = []
        presenter.confirmDestructive = { confirmation, host, _ in
            #expect(host === window)
            titles.append(confirmation.action)
            messages.append(confirmation.message)
            #expect(confirmation.alert().buttons.first?.keyEquivalent.isEmpty == true)
        }
        window.layoutIfNeeded()
        let buttons = SharedFixtures.descendants(controller.view, of: PartsButton.self)
        for id in ["restore", "restoreFile.0", "restoreHunk", "clear"] {
            let button = try #require(buttons.first { $0.accessibilityIdentifier() == "agentControl.flight." + id })
            #expect(button.accessibilityPerformPress())
        }
        #expect(titles == ["Restore Turn", "Restore File", "Restore Hunk", "Clear"])
        #expect(messages.allSatisfy { $0.hasSuffix("?") })
        #expect(try await service.listSnapshots(in: repo.url) == [saved])
        #expect(try String(contentsOf: repo.url.appending(path: "file"), encoding: .utf8) == "working\n")
    }

    @Test func returnInTheFileListCapturesAndClosingAllowsTheWriteToFinish() async throws {
        UITestSupport.bootstrap()
        let repo = try TemporaryRepository()
        try repo.commit("file", "base\n", message: "base")
        let service = FlightRecorderService()
        await service.setEnabled(true, for: repo.url)
        try repo.write("file", "turn\n")
        _ = try await service.captureSnapshot(in: repo.url)
        try repo.write("file", "working\n")
        let facade = AgentControlFacade(flightRecorder: service)
        facade.presentFlightRecorder(for: repo.url)
        let window = try #require(NSApp.windows.first { $0.subtitle == repo.url.lastPathComponent })
        let controller = try #require(window.contentViewController as? AgentFlightRecorderViewController)
        try await loaded(controller.presenter)
        controller.presenter.confirmDestructive = { _, _, _ in Issue.record("Return requested a destructive action") }
        let list = try #require(
            SharedFixtures.descendants(controller.view, of: NSTableView.self).first {
                $0.accessibilityIdentifier() == "agentControl.flight.files"
            })
        window.makeFirstResponder(list)
        let enter = try #require(SharedEvents.key("\r", code: KeyPress.returnKey))
        #expect(window.performKeyEquivalent(with: enter))
        window.close()
        try #require(
            await SharedFixtures.waitUntil(seconds: 20) {
                controller.presenter.state == .idle
            })
        let snapshots = try await service.listSnapshots(in: repo.url)
        #expect(snapshots.count == 2)
        let newest = try #require(snapshots.first)
        #expect(try repo.git("show", newest.id + ":file") == "working\n")
    }

    @Test func scrubbingKeepsDiffVisibleAndPreservesComparisonAcrossReloads() async throws {
        let repo = try TemporaryRepository()
        let service = FlightRecorderService()
        await service.setEnabled(true, for: repo.url)
        let first = try await service.captureSnapshot(in: repo.url)
        try repo.write("file", "changed")
        _ = try await service.captureSnapshot(in: repo.url)
        let presenter = FlightRecorderPresenter(service: service, repositoryRoot: repo.url)
        let controller = AgentFlightRecorderViewController(presenter: presenter)
        let window = UITestSupport.host(controller)
        defer { window.close() }
        presenter.load()
        try await loaded(presenter)
        let pane = try #require(SharedFixtures.descendants(controller.view, of: DiffView.self).first)
        let previous = presenter.diff
        presenter.selectTurn(index: 0)
        #expect(!pane.isHiddenOrHasHiddenAncestor)
        #expect(!controller.scrubber.isHidden)
        #expect(presenter.diff == previous)
        try await loaded(presenter)
        #expect(presenter.comparison == .previous)
        #expect(presenter.effectiveComparison == .workingTree)
        let menu = try #require(
            SharedFixtures.descendants(controller.view, of: NSPopUpButton.self).first {
                $0.accessibilityIdentifier() == "agentControl.flight.comparison"
            })
        #expect(menu.indexOfSelectedItem == 0)
        presenter.selectTurn(index: 1)
        try await loaded(presenter)
        #expect(presenter.effectiveComparison == .previous)
        presenter.selectComparison(toSnapshotID: first.id)
        presenter.load()
        try await loaded(presenter)
        #expect(presenter.effectiveComparison == .turn(first.id))
    }

    @Test func historyForgetsEmptyKeysAfterListingAndClearing() async throws {
        let repo = try TemporaryRepository()
        let history = FlightHistory(service: FlightRecorderService(), root: repo.url)
        let registry = "Gita.AgentControl.FlightHistory." + repo.url.standardizedFileURL.resolvingSymlinksInPath().path
        defer { UserDefaults.standard.removeObject(forKey: registry) }
        history.remember("gone")
        let turn = try await history.service.captureSnapshot(in: repo.url, key: "retained")
        history.remember("retained")
        #expect(try await history.snapshots() == [turn])
        #expect(UserDefaults.standard.stringArray(forKey: registry) == ["retained"])
        try await history.clear()
        #expect(UserDefaults.standard.object(forKey: registry) == nil)
        #expect(try await history.snapshots().isEmpty)
    }
}
