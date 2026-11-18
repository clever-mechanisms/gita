import Foundation
import Testing

@testable import GitaCore

/// History walks that overlap are each tracked by their own start.
@Suite struct HistoryWalksTests {
    private let start = ContinuousClock.now

    /// A newer walk ending first leaves the older one running and counted.
    @Test func aWalkEndingFirstDoesNotEndTheOneBesideIt() async {
        let service = GitService(root: FileManager.default.temporaryDirectory)
        await service.startWalk(start)
        await service.startWalk(start + .milliseconds(100))
        await service.noteWalk(.milliseconds(10), start: start + .milliseconds(100))
        #expect(await service.slowWalkAlone(now: start + .seconds(1)))
        await service.noteWalk(.seconds(1), start: start)
        #expect(await !service.slowWalkAlone(now: start + .seconds(2)))
    }

    @Test func overlappingWalksCountAsTheSlowestOfThem() {
        var walks = HistoryWalks()
        walks.start(start)
        walks.start(start + .seconds(1))
        walks.end(.seconds(2), start: start)
        #expect(walks.oldest == start + .seconds(1))
        // The fast one ends last: the slow one beside it still counts.
        walks.end(.milliseconds(20), start: start + .seconds(1))
        #expect(walks.lastDuration == .seconds(2))
        #expect(walks.oldest == nil)
        // A walk on its own afterwards is the latest.
        walks.start(start + .seconds(5))
        walks.end(.milliseconds(30), start: start + .seconds(5))
        #expect(walks.lastDuration == .milliseconds(30))
    }

    @Test func aBuiltGraphForgetsTheDuration() {
        var walks = HistoryWalks()
        walks.start(start)
        walks.start(start + .seconds(1))
        walks.end(.seconds(2), start: start)
        walks.forgetDuration()
        #expect(walks.lastDuration == .zero)
        walks.end(.milliseconds(20), start: start + .seconds(1))
        #expect(walks.lastDuration == .milliseconds(20))
    }

    /// A duration noted without a start (no tracked walk) is simply the latest.
    @Test func anUntrackedWalkIsTheLatest() {
        var walks = HistoryWalks()
        walks.end(.seconds(2), start: nil)
        #expect(walks.lastDuration == .seconds(2))
        walks.end(.milliseconds(5), start: nil)
        #expect(walks.lastDuration == .milliseconds(5))
    }
}
