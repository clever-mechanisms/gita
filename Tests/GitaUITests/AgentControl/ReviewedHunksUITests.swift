import AppKit
import GitaCore
import Testing

@testable import GitaUI

@Suite @MainActor
struct AgentControlReviewedHunksUITests {
    @Test func progressFiltersPersistenceAndClear() async throws {
        UITestSupport.bootstrap()
        let repo = try TemporaryRepository()
        let url = repo.url.appending(path: "reviewed.json")
        let presenter = ReviewedHunksPresenter(store: ReviewedHunksStore(storageURL: url))
        let hashes = ["+one", "+two", "+three"].map { ReviewedHunkHasher.hash(filePath: "source", hunkLines: [$0]) }
        let bar = ReviewedHunksBarView(presenter: presenter)
        presenter.load(filePath: "source", hashes: hashes)
        presenter.toggle(hash: hashes[1], filePath: "source")
        await presenter.queue.last?.value
        #expect(presenter.progress?.reviewed == 1)
        #expect(presenter.progress?.total == 3)
        #expect(SharedFixtures.texts(bar).contains(String(localized: "1/3 reviewed")))
        #expect(presenter.visibleHunkIndices(for: hashes) == [0, 1, 2])
        presenter.setFilter(.unreviewedOnly)
        #expect(presenter.visibleHunkIndices(for: hashes) == [0, 2])
        presenter.setFilter(.reviewedOnly)
        #expect(presenter.visibleHunkIndices(for: hashes) == [1])
        let group = try #require(
            SharedFixtures.descendants(bar, of: NSStackView.self).first {
                $0.accessibilityRole() == .radioGroup
            })
        let selected = SharedFixtures.descendants(group, of: PartsButton.self).filter { $0.isAccessibilitySelected() }
        #expect(selected.map { $0.accessibilityLabel() } == [String(localized: "Reviewed")])
        let reopened = ReviewedHunksStore(storageURL: url)
        #expect(await reopened.isReviewed(hashes[1]))
        presenter.toggle(hash: hashes[0], filePath: "source")
        presenter.clearFile("source")
        presenter.cancel()
        await presenter.queue.last?.value
        #expect(presenter.progress?.reviewed == 0)
        presenter.toggle(hash: hashes[2], filePath: "source")
        presenter.clearAll()
        await presenter.queue.last?.value
        #expect(!presenter.isReviewed(hashes[2]))
    }

    @Test func accessibleToggleInvokesAction() {
        UITestSupport.bootstrap()
        let counter = SharedCounter()
        let button = ReviewedHunksBarView.makeHunkToggleButton(isReviewed: true) { [weak counter] in
            counter?.value += 1
        }
        #expect(button.accessibilityLabel() == String(localized: "Mark unreviewed"))
        #expect(button.accessibilityValue() as? String == String(localized: "Reviewed"))
        #expect(button.accessibilityIdentifier() == "agentControl.review.toggle")
        #expect(button.accessibilityPerformPress())
        #expect(counter.value == 1)
    }

    @Test func toolWindowsAreStandaloneAndReusedPerRepository() throws {
        UITestSupport.bootstrap()
        let repo = try TemporaryRepository()
        let facade = AgentControlFacade()
        for show in [facade.presentCollisionRadar, facade.presentFlightRecorder, { facade.showArena(for: $0) }] {
            show(repo.url)
            let first = try #require(NSApp.windows.first { $0.isVisible && $0.subtitle == repo.url.lastPathComponent })
            #expect(first.sheetParent == nil)
            #expect(first.styleMask.contains(.resizable))
            #expect(!first.frameAutosaveName.isEmpty)
            first.close()
            show(repo.url)
            #expect(first.isVisible)
            first.close()
        }
    }

    @Test func facadeOrdersOptInAndHookAndExposesCapturedTurn() async throws {
        UITestSupport.bootstrap()
        let repo = try TemporaryRepository()
        try repo.commit("source", "one", message: "base")
        let service = FlightRecorderService()
        let facade = AgentControlFacade(flightRecorder: service)
        let radar = facade.makeCollisionRadarViewController(for: repo.url)
        let flight = facade.makeFlightRecorderViewController(for: repo.url)
        let presenter = facade.makeReviewedHunksPresenter(for: repo.url)
        #expect(
            facade.makeReviewedHunksBar(presenter: presenter).accessibilityIdentifier() == "agentControl.review.bar")
        #expect(radar.view.accessibilityIdentifier() == "agentControl.radar.root")
        #expect(flight.view.accessibilityIdentifier() == "agentControl.flight.root")
        let event = AgentHookEvent.claude(event: "Stop", input: Data(#"{"session_id":"test-session"}"#.utf8), pids: [])
        facade.setFlightRecorderEnabled(true, for: repo.url)
        facade.handleHookEvent(event, repositoryRoot: repo.url)
        #expect(await facade.isFlightRecorderEnabled(for: repo.url))
        #expect(try await service.listSnapshots(in: repo.url, key: "test-session").count == 1)
        flight.presenter.load()
        try #require(await SharedFixtures.waitUntil(seconds: 20) { flight.presenter.diff != nil })
        #expect(flight.presenter.selectedTurn?.trigger == .agentStop)
        radar.presenter.scan()
        facade.cancelAll()
        #expect(radar.presenter.state == .idle)
        #expect(flight.presenter.state == .idle)
    }
}
