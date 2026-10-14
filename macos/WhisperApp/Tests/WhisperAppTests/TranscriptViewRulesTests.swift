import Testing
@testable import WhisperApp

struct TranscriptViewRulesTests {
    @Test func readingModeIsDefaultAndShowsTimecodeList() {
        #expect(TranscriptViewRules.body(isEditing: false, hasSegments: true) == .segmentList)
        #expect(TranscriptViewRules.editToggleLabel(isEditing: false) == "編輯")
        #expect(!TranscriptViewRules.showsClearButton(isEditing: false))
    }

    @Test func editingModeShowsOnlyEditorAndClearButton() {
        #expect(TranscriptViewRules.body(isEditing: true, hasSegments: true) == .editor)
        #expect(TranscriptViewRules.body(isEditing: true, hasSegments: false) == .editor)
        #expect(TranscriptViewRules.editToggleLabel(isEditing: true) == "完成")
        #expect(TranscriptViewRules.showsClearButton(isEditing: true))
    }

    @Test func recordsWithoutSegmentsReadAsPlainText() {
        #expect(TranscriptViewRules.body(isEditing: false, hasSegments: false) == .readOnlyText)
    }

    @Test func unsavedNoticeOnlyInReadingModeWithDirtyDraft() {
        #expect(TranscriptViewRules.showsUnsavedNotice(isEditing: false, isDraftDirty: true))
        #expect(!TranscriptViewRules.showsUnsavedNotice(isEditing: false, isDraftDirty: false))  // 儲存後消失
        #expect(!TranscriptViewRules.showsUnsavedNotice(isEditing: true, isDraftDirty: true))
    }

    @Test func jobControlsOnlyWhileTranscribing() {
        #expect(TranscriptViewRules.showsJobControls(hasActiveRequest: true))
        #expect(!TranscriptViewRules.showsJobControls(hasActiveRequest: false))
        #expect(StatusTextRules.jobStatus("Submitting") == "送出中…")
        #expect(StatusTextRules.jobStatus("Completed") == "已完成")
        #expect(StatusTextRules.jobStatus("Failed") == "轉錄失敗")
        #expect(StatusTextRules.jobStatus("Idle").isEmpty)
    }

    @Test func editedDraftIsShownInsteadOfStaleTimecodes() {
        let segments = [TranscriptionSegment(start: 0, end: 1, text: "原文")]
        // 講者辨識或改名後（未儲存）：閱讀模式顯示草稿，不是舊的時間碼清單
        let dirty = TranscriptViewRules.draftDiverged(isDraftDirty: true, segmentsWhenEdited: segments, currentSegments: segments)
        #expect(dirty)
        #expect(TranscriptViewRules.body(isEditing: false, hasSegments: true, draftDiverged: dirty) == .readOnlyText)
        // 儲存後：segments 沒有重新轉錄，仍顯示已編輯的文字＋說明，不再提示未儲存
        let saved = TranscriptViewRules.draftDiverged(isDraftDirty: false, segmentsWhenEdited: segments, currentSegments: segments)
        #expect(saved)
        #expect(!TranscriptViewRules.showsUnsavedNotice(isEditing: false, isDraftDirty: false))
        #expect(TranscriptViewRules.showsEditedNotice(isEditing: false, isDraftDirty: false, draftDiverged: saved))
        // 重新轉錄後 segments 變了：回到時間碼清單
        let retranscribed = TranscriptViewRules.draftDiverged(
            isDraftDirty: false, segmentsWhenEdited: segments,
            currentSegments: [TranscriptionSegment(start: 0, end: 2, text: "新結果")]
        )
        #expect(!retranscribed)
        #expect(TranscriptViewRules.body(isEditing: false, hasSegments: true, draftDiverged: retranscribed) == .segmentList)
        // 編輯後未儲存就切走再切回：沒有快照（只在儲存時記錄），回到時間碼清單
        #expect(!TranscriptViewRules.draftDiverged(isDraftDirty: false, segmentsWhenEdited: nil, currentSegments: segments))
        // 從未編輯
        #expect(!TranscriptViewRules.draftDiverged(isDraftDirty: false, segmentsWhenEdited: nil, currentSegments: segments))
    }

    @Test func jobControlsHiddenPerChunkDuringLiveOrMixedCapture() {
        #expect(!TranscriptViewRules.showsJobControls(hasActiveRequest: true, isChunkedCaptureActive: true))
        #expect(TranscriptViewRules.showsJobControls(hasActiveRequest: true, isChunkedCaptureActive: false))
    }

    @Test func autoScrollOnlyWhenAlreadyAtBottom() {
        #expect(TranscriptViewRules.shouldAutoScroll(isAtBottom: true, segmentCountIncreased: true))
        #expect(!TranscriptViewRules.shouldAutoScroll(isAtBottom: false, segmentCountIncreased: true))
        #expect(!TranscriptViewRules.shouldAutoScroll(isAtBottom: true, segmentCountIncreased: false))
    }
}
