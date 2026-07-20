import Foundation

enum RecordingState: Equatable, Sendable {
    case idle
    case requestingPermission
    case ready
    case recording(startedAt: Date)
    case finalizing
    case recorded(URL)
    case failed(String)

    var canStart: Bool {
        self == .ready
    }

    var canStop: Bool {
        if case .recording = self { return true }
        return false
    }
}

enum RecordingStateError: Error, Equatable {
    case invalidTransition
}

struct RecordingStateMachine: Sendable {
    private(set) var state: RecordingState = .idle

    mutating func requestPermission() throws {
        guard state == .idle else { throw RecordingStateError.invalidTransition }
        state = .requestingPermission
    }

    mutating func permissionResolved(granted: Bool) throws {
        guard state == .requestingPermission else { throw RecordingStateError.invalidTransition }
        state = granted ? .ready : .failed("Microphone permission denied")
    }

    mutating func start(at date: Date = Date()) throws {
        guard state == .ready else { throw RecordingStateError.invalidTransition }
        state = .recording(startedAt: date)
    }

    mutating func stop() throws {
        guard state.canStop else { throw RecordingStateError.invalidTransition }
        state = .finalizing
    }

    mutating func finalized(at url: URL) throws {
        guard state == .finalizing else { throw RecordingStateError.invalidTransition }
        state = .recorded(url)
    }

    mutating func fail(_ message: String) {
        state = .failed(message)
    }

    mutating func reset() {
        state = .idle
    }
}
