import Testing
@testable import WhisperApp

struct CaptureUIRulesTests {
    @Test
    func visibleAppIdentityIsDistinctFromClassic() {
        #expect(AppIdentity.displayName == "Whisper Swift")
    }

    @Test
    func pendingCaptureStartLocksModeSelection() {
        #expect(CaptureUIRules.shouldLockMode(
            standardPendingOrActive: true,
            livePendingOrActive: false,
            mixedPendingOrActive: false
        ))
        #expect(CaptureUIRules.shouldLockMode(
            standardPendingOrActive: false,
            livePendingOrActive: false,
            mixedPendingOrActive: true
        ))
    }

    @Test
    func liveRecordingAndRecoveryRemainStoppable() {
        #expect(CaptureUIRules.liveIsStoppable(recording: true, recovering: false))
        #expect(CaptureUIRules.liveIsStoppable(recording: false, recovering: true))
        #expect(!CaptureUIRules.liveIsStoppable(recording: false, recovering: false))
    }

    @Test
    func activeChunkJobDoesNotDisableLiveStop() {
        #expect(CaptureUIRules.stopIsEnabled(mode: .live, workerHasActiveJob: true))
        #expect(!CaptureUIRules.stopIsEnabled(mode: .standard, workerHasActiveJob: true))
    }

    @Test
    func activeChunkJobDoesNotDisableMixedStop() {
        // Mixed mode rotates and submits a transcription job every 15s,
        // so an in-flight job must never block the user from stopping the recording.
        #expect(CaptureUIRules.stopIsEnabled(mode: .mixed, workerHasActiveJob: true))
    }

    @Test
    func explicitStopAndTranscribePresentsItsCompletionEvenWithAnOlderDirtyDraft() {
        #expect(CaptureUIRules.shouldPresentCompletedResult(
            isDraftDirty: true,
            explicitlyRequestedPresentation: true
        ))
        #expect(!CaptureUIRules.shouldPresentCompletedResult(
            isDraftDirty: true,
            explicitlyRequestedPresentation: false
        ))
    }
}
