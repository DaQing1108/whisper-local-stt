import Foundation

final class SystemAudioCallbackGate: @unchecked Sendable {
    private struct State { var accepting = true; var inFlight = 0 }
    private let lock = NSCondition()
    private var generation = 0
    private var states: [Int: State] = [:]

    func open() -> Int {
        lock.withLock {
            generation += 1
            states[generation] = State()
            return generation
        }
    }

    func begin(generation candidate: Int) -> Bool {
        lock.lock()
        guard var state = states[candidate], state.accepting else {
            lock.unlock()
            return false
        }
        state.inFlight += 1
        states[candidate] = state
        lock.unlock()
        return true
    }

    func isAccepting(generation candidate: Int) -> Bool {
        lock.withLock { states[candidate]?.accepting == true }
    }

    func end(generation candidate: Int) {
        lock.lock()
        guard var state = states[candidate] else { lock.unlock(); return }
        state.inFlight -= 1
        states[candidate] = state
        lock.broadcast()
        lock.unlock()
    }

    /// Must not be called synchronously from a callback that began this generation.
    func close(generation candidate: Int) {
        lock.lock()
        guard var state = states[candidate] else { lock.unlock(); return }
        state.accepting = false
        states[candidate] = state
        while states[candidate]?.inFlight != 0 { lock.wait() }
        states[candidate] = nil
        lock.unlock()
    }
}
