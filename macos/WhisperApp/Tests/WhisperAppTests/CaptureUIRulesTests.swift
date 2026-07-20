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
            systemPendingOrActive: false,
            mixedPendingOrActive: false
        ))
        #expect(CaptureUIRules.shouldLockMode(
            standardPendingOrActive: false,
            livePendingOrActive: false,
            systemPendingOrActive: true,
            mixedPendingOrActive: false
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
        #expect(CaptureUIRules.stopIsEnabled(mode: .system, workerHasActiveJob: true))
        #expect(!CaptureUIRules.stopIsEnabled(mode: .standard, workerHasActiveJob: true))
    }

    @Test
    func systemAudioStartRemainsActionableWhenPermissionNeedsAttention() {
        #expect(CaptureUIRules.systemAudioStartIsEnabled(
            workerReady: true,
            workerHasActiveRequest: false,
            conflictingCaptureActive: false,
            controllerCanStart: true
        ))
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
