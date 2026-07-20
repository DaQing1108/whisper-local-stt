import Foundation
import Testing
@testable import WhisperApp

struct RecordingStateTests {
    @Test
    func followsPermissionRecordAndFinalizeLifecycle() throws {
        var machine = RecordingStateMachine()
        let startedAt = Date(timeIntervalSince1970: 123)
        let output = URL(fileURLWithPath: "/tmp/recording.wav")

        try machine.requestPermission()
        try machine.permissionResolved(granted: true)
        try machine.start(at: startedAt)
        #expect(machine.state == .recording(startedAt: startedAt))
        try machine.stop()
        try machine.finalized(at: output)

        #expect(machine.state == .recorded(output))
    }

    @Test
    func rejectsStopBeforeRecording() {
        var machine = RecordingStateMachine()
        #expect(throws: RecordingStateError.invalidTransition) { try machine.stop() }
    }
}
