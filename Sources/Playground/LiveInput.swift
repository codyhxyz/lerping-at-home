import Foundation
import os
import QuartzCore

/// The latest value of a live input — system audio, a tracked head — handed
/// from the queue that produces it to the render thread, which polls it once
/// a frame.
///
/// A reader gets `idle` once the producer has gone quiet for longer than
/// `staleAfter`: a stalled device or a camera that stopped delivering must
/// drop a shader back to its plain look, not freeze it mid-gesture.
final class LiveInput<Value: Sendable>: Sendable {
    private struct State: Sendable { var value: Value; var stamp: CFTimeInterval }
    private let state: OSAllocatedUnfairLock<State>
    private let idle: Value
    private let staleAfter: CFTimeInterval

    init(idle: Value, staleAfter: CFTimeInterval) {
        self.idle = idle
        self.staleAfter = staleAfter
        state = OSAllocatedUnfairLock(initialState: State(value: idle, stamp: 0))
    }

    func publish(_ value: Value) {
        let now = CACurrentMediaTime()
        state.withLock { $0 = State(value: value, stamp: now) }
    }

    func reset() { state.withLock { $0 = State(value: idle, stamp: 0) } }

    var current: Value {
        let now = CACurrentMediaTime()
        return state.withLock { now - $0.stamp > staleAfter ? idle : $0.value }
    }
}
