import AppKit
import GitaCore
import Testing

@testable import GitaUI

@Suite @MainActor
struct AgentControlFlightRecorderUITests {
    @Test func writingMessagesIdentifyThePendingOperation() {
        UITestSupport.bootstrap()
        let cases: [(FlightWriteKind, String)] = [
            (.enabling, "Enabling recording…"), (.disabling, "Disabling recording…"),
            (.capturing, "Capturing snapshot…"), (.clearing, "Clearing snapshots…"),
        ]
        for (kind, message) in cases {
            #expect(AgentFlightRecorderViewController.writingMessage(kind) == message)
        }
    }

    private func settle(_ presenter: FlightRecorderPresenter) async throws {
        try #require(
            await SharedFixtures.waitUntil(seconds: 20) {
                switch presenter.state {
                case .restoring, .loading, .writing: false
                default: true
                }
            })
    }

    @Test func optInCaptureCompareRestoreAndClear() async throws {
        let repo = try TemporaryRepository()
        try repo.commit("file", "original\n", message: "base")
        let presenter = FlightRecorderPresenter(service: FlightRecorderService(), repositoryRoot: repo.url)
        presenter.confirmDestructive = { _, _, accept in accept() }
        presenter.load()
        try await settle(presenter)
        #expect(presenter.state == .disabled)
        presenter.setEnabled(true)
        try await settle(presenter)
        #expect(presenter.state == .empty)
        try repo.write("file", "captured\n")
        presenter.captureManualSnapshot()
        try await settle(presenter)
        let snapshot = try #require(presenter.selectedTurn)
        #expect(presenter.diff?.files == ["file"])
        #expect(presenter.diff?.diffText.contains("+captured") == true)
        try repo.write("file", "working\n")
        presenter.selectComparison(toSnapshotID: nil)
        try await settle(presenter)
        let patch = try #require(presenter.patch)
        #expect(patch.document.canApplyHunks)
        #expect(patch.text.contains("+working"))
        presenter.restoreHunk(path: "file", hunkIndex: 0, expectedDiff: patch.text, on: nil)
        #expect(presenter.state == .restoring(snapshotID: snapshot.id))
        try await settle(presenter)
        #expect(presenter.diff?.files.isEmpty == true)
        #expect(presenter.turns.last?.label == String(localized: "Before restore"))
        #expect(try repo.git("show", try #require(presenter.turns.last).id + ":file") == "working\n")
        try repo.write("file", "again\n")
        presenter.restoreFile("file", on: nil)
        presenter.cancel()
        try await settle(presenter)
        #expect(try String(contentsOf: repo.url.appending(path: "file"), encoding: .utf8) == "captured\n")
        #expect(try repo.git("show", try #require(presenter.turns.last).id + ":file") == "again\n")
        presenter.selectFile(nil)
        #expect(presenter.feedback.isEmpty)
        try repo.write("file", "whole turn\n")
        presenter.restoreSelectedTurn(on: nil)
        try await settle(presenter)
        #expect(try repo.git("show", try #require(presenter.turns.last).id + ":file") == "whole turn\n")
        presenter.clearSnapshots(on: nil)
        try await settle(presenter)
        #expect(presenter.state == .empty)
    }

    @Test func staleHunkLeavesTheWorkingFileUntouched() async throws {
        let repo = try TemporaryRepository()
        try repo.commit("a", "first\n", message: "base")
        try repo.commit("b", "second\n", message: "base")
        let service = FlightRecorderService()
        await service.setEnabled(true, for: repo.url)
        _ = try await service.captureSnapshot(in: repo.url)
        try repo.write("a", "changed first\n")
        try repo.write("b", "changed second\n")
        let presenter = FlightRecorderPresenter(service: service, repositoryRoot: repo.url)
        presenter.confirmDestructive = { _, _, accept in accept() }
        presenter.load()
        try await settle(presenter)
        presenter.selectComparison(toSnapshotID: nil)
        try await settle(presenter)
        presenter.selectFile("b")
        let patch = try #require(presenter.patch)
        #expect(patch.text.hasPrefix("diff --git a/b b/b"))
        #expect(patch.document.hunks.count == 1)
        try repo.write("b", "newer edit\n")
        presenter.restoreHunk(path: "b", hunkIndex: 0, expectedDiff: patch.text, on: nil)
        try await settle(presenter)
        guard case .failed = presenter.state else {
            Issue.record("A stale hunk must require a fresh comparison")
            return
        }
        #expect(try String(contentsOf: repo.url.appending(path: "b"), encoding: .utf8) == "newer edit\n")
        presenter.load()
        try await settle(presenter)
        #expect(presenter.patch?.text.contains("+newer edit") == true)
    }

    @Test func scrubberKeysAccessibilityAndAppearance() async throws {
        UITestSupport.bootstrap()
        let repo = try TemporaryRepository()
        try repo.commit("file", "one\n", message: "base")
        let service = FlightRecorderService()
        await service.setEnabled(true, for: repo.url)
        let first = try await service.captureSnapshot(in: repo.url)
        try repo.write("file", "two\n")
        _ = try await service.captureSnapshot(in: repo.url)
        let presenter = FlightRecorderPresenter(service: service, repositoryRoot: repo.url)
        let controller = AgentFlightRecorderViewController(presenter: presenter)
        let window = UITestSupport.host(controller)
        defer {
            presenter.cancel()
            window.close()
        }
        presenter.load()
        try await settle(presenter)
        #expect(presenter.selectedTurnIndex == 1)
        let left = try #require(SharedEvents.key("", code: KeyPress.leftArrow))
        controller.scrubber.keyDown(with: left)
        try await settle(presenter)
        #expect(presenter.selectedTurnIndex == 0)
        #expect(controller.scrubber.accessibilityRole() == .slider)
        #expect((controller.scrubber.accessibilityValue() as? String)?.contains("1") == true)
        let right = try #require(SharedEvents.key("", code: KeyPress.rightArrow))
        controller.scrubber.keyDown(with: right)
        try await settle(presenter)
        presenter.selectComparison(toSnapshotID: first.id)
        try await settle(presenter)
        #expect(presenter.comparison == .turn(first.id))
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: name)
            window.layoutIfNeeded()
            let preview = try #require(SharedFixtures.descendants(controller.view, of: DiffView.self).first)
            #expect(preview.bounds.width > 180)
            #expect(preview.bounds.height > 100)
            #expect(preview.table.enclosingScrollView?.contentSize.height ?? 0 > 100)
            #expect(controller.scrubber.bounds.width > 0)
            #expect(controller.scrubber.accessibilityIdentifier() == "agentControl.flight.scrubber")
            UITestSupport.render(controller.view)
        }
    }

    @Test func recordingUsesAccentSwitchAndHeaderSupportsBackCallback() throws {
        UITestSupport.bootstrap()
        let repo = try TemporaryRepository()
        let controller = AgentControlFacade().makeFlightRecorderViewController(for: repo.url)
        var wentBack = false
        controller.onBack = { wentBack = true }
        let window = UITestSupport.host(controller)
        defer {
            controller.presenter.cancel()
            window.close()
        }
        let toggle = try #require(
            SharedFixtures.descendants(controller.view, of: AccentSwitch.self).first {
                $0.accessibilityIdentifier() == "agentControl.flight.recording"
            })
        #expect(toggle.accessibilitySubrole() == .switch)
        let back = try #require(
            SharedFixtures.descendants(controller.view, of: PartsButton.self).first {
                $0.accessibilityIdentifier() == "agentControl.flight.back"
            })
        #expect(!back.isHidden && back.accessibilityPerformPress() && wentBack)
    }
}
