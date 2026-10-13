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

    @Test
    func finalizedMixedAudioResultSyncsOnlyWhenDraftIsClean() {
        #expect(CaptureUIRules.shouldSyncFinalizedMixedAudioResult(isDraftDirty: false))
        #expect(!CaptureUIRules.shouldSyncFinalizedMixedAudioResult(isDraftDirty: true))
    }

    private func notice(
        _ mode: AudioInputMode = .mixed, recording: Bool, diarization: Bool, model: Bool
    ) -> String? {
        CaptureUIRules.transcriptionDeferralNotice(
            mode: mode, isRecordingOrStarting: recording,
            diarizationInProgress: diarization, modelOperationInProgress: model
        )
    }

    @Test
    func deferralNoticeAppearsForDiarizationWhileRecording() {
        #expect(notice(recording: true, diarization: true, model: false)
            == "講者辨識進行中，這次錄音的轉錄會等辨識結束後才開始（錄音檔會正常儲存）")
        #expect(notice(.live, recording: true, diarization: true, model: false)
            == "講者辨識進行中，這次錄音的轉錄會等辨識結束後才開始（錄音檔會正常儲存）")
    }

    @Test
    func deferralNoticeIsAbsentWhenNotRecordingOrNothingBusy() {
        #expect(notice(recording: false, diarization: true, model: true) == nil)
        #expect(notice(recording: true, diarization: false, model: false) == nil)
    }

    @Test
    func deferralNoticeForModelOperationAndDiarizationTakesPriority() {
        #expect(notice(recording: true, diarization: false, model: true)
            == "模型下載或檢查進行中，這次錄音的轉錄會等它結束後才開始（錄音檔會正常儲存）")
        #expect(notice(recording: true, diarization: true, model: true)
            == "講者辨識進行中，這次錄音的轉錄會等辨識結束後才開始（錄音檔會正常儲存）")
    }

    @Test
    func deferralNoticeUsesStopWordingInStandardMode() {
        #expect(notice(.standard, recording: true, diarization: true, model: false)
            == "講者辨識進行中，停止後的轉錄會等辨識結束後才開始（錄音檔會正常儲存）")
        #expect(notice(.standard, recording: true, diarization: false, model: true)
            == "模型下載或檢查進行中，停止後的轉錄會等它結束後才開始（錄音檔會正常儲存）")
    }
}
