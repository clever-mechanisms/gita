import os

/// A value settled once, by whichever comes first: a result, or a cancellation that may arrive even before the
/// continuation exists. Every continuation set gets that first value, however the two race; a later value is
/// ignored, and no continuation is left waiting once a value is in.
final class ResumeOnce<Value: Sendable>: Sendable {
    private enum State {
        /// No value yet: the continuations set so far wait for it.
        case waiting([CheckedContinuation<Value, Never>])
        case settled(Value)
    }
    private let state = OSAllocatedUnfairLock(initialState: State.waiting([]))

    func set(_ continuation: CheckedContinuation<Value, Never>) {
        let value: Value? = state.withLock { state in
            switch state {
            case .waiting(let waiting):
                state = .waiting(waiting + [continuation])
                return nil
            case .settled(let value):
                return value
            }
        }
        if let value { continuation.resume(returning: value) }
    }

    func resume(with value: Value) {
        let waiting: [CheckedContinuation<Value, Never>] = state.withLock { state in
            guard case .waiting(let waiting) = state else { return [] }
            state = .settled(value)
            return waiting
        }
        for continuation in waiting { continuation.resume(returning: value) }
    }
}
