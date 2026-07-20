import Testing
@testable import WhisperApp

struct SystemAudioCaptureErrorTests {
    @Test
    func exposesActionableStreamFailureMessage() {
        let error = SystemAudioCaptureError.streamStopped("permission revoked")
        #expect(error.localizedDescription == "System audio capture stopped: permission revoked")
    }
}
