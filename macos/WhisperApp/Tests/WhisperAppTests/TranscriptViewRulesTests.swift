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

    @Test func autoScrollOnlyWhenAlreadyAtBottom() {
        #expect(TranscriptViewRules.shouldAutoScroll(isAtBottom: true, segmentCountIncreased: true))
        #expect(!TranscriptViewRules.shouldAutoScroll(isAtBottom: false, segmentCountIncreased: true))
        #expect(!TranscriptViewRules.shouldAutoScroll(isAtBottom: true, segmentCountIncreased: false))
    }
}
