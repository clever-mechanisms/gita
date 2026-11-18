import Foundation
import Testing

@testable import GitaCore

/// The first value wins, whether it comes before or after the continuation, and every continuation gets it.
@Suite struct ResumeOnceTests {
    private func wait(_ gate: ResumeOnce<Int>, then: @escaping @Sendable () -> Void = {}) async -> Int {
        await withCheckedContinuation { continuation in
            gate.set(continuation)
            then()
        }
    }

    @Test func aValueAfterTheContinuationResumesIt() async {
        let gate = ResumeOnce<Int>()
        #expect(await wait(gate) { gate.resume(with: 1) } == 1)
    }

    @Test func aValueBeforeTheContinuationIsKeptForIt() async {
        let gate = ResumeOnce<Int>()
        gate.resume(with: 1)
        #expect(await wait(gate) == 1)
    }

    @Test func onlyTheFirstValueCounts() async {
        let gate = ResumeOnce<Int>()
        #expect(
            await wait(gate) {
                gate.resume(with: 1)
                gate.resume(with: 2)
            } == 1)
        gate.resume(with: 3)
        #expect(await wait(gate) == 1)
    }

    /// A second continuation is not left waiting: it gets the same value, set before it or after.
    @Test func everyContinuationGetsTheValue() async {
        let gate = ResumeOnce<Int>()
        async let first = wait(gate)
        async let second = wait(gate)
        try? await Task.sleep(for: .milliseconds(20))
        gate.resume(with: 7)
        #expect(await [first, second] == [7, 7])
        #expect(await wait(gate) == 7)
    }

    @Test func aCancellationBeforeTheTaskEndsWins() async {
        let task = Task<Int, any Error> {
            try await Task.sleep(for: .seconds(30))
            return 1
        }
        defer { task.cancel() }
        let waiter = Task { await GitService.unlessCancelled(task) }
        waiter.cancel()
        #expect(await waiter.value == nil)
    }
}
