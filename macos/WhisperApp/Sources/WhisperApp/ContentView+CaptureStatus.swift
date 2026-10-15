import SwiftUI

/// Publishes the capture state to `CaptureStatusBoard` (menu-bar indicator, window guard).
/// Derived from existing state only — the start/stop flows themselves are untouched, and any
/// path that ends a capture (stop, failure, recovery give-up) clears the board automatically.
extension ContentView {
    var captureSnapshot: CaptureSnapshot {
        let phase: CapturePhase = switch audioMode {
        case .standard: CapturePhase.standard(recording.state, transcriptionInFlight: standardRecordingTranscribing)
        case .live: CapturePhase.live(liveRecording.state)
        case .mixed: CapturePhase.mixed(mixedAudioRecording.state, isDraining: mixedAudioRecording.isDraining)
        }
        return CaptureSnapshot(
            mode: audioMode,
            phase: phase,
            startedAt: captureStartedAt,
            canStop: isPrimaryRecording && primaryActionEnabled,
            statusText: primaryStatusText,
            silenceWarnings: inputSilenceWarnings
        )
    }

    /// The post-stop job of *this* recording: `stopRecording()` sets `selectedFile` to the recorded
    /// file, and importing other audio replaces it, so an unrelated later job doesn't count.
    private var standardRecordingTranscribing: Bool {
        guard worker.activeRequestID != nil, case .recorded(let url) = recording.state else { return false }
        return selectedFile == url
    }
}
