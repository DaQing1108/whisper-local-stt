import Testing
@testable import WhisperApp

struct SaveButtonRuleTests {
    // AC-C1
    @Test func saveButtonOnlyWhenDirty() {
        #expect(!TranscriptViewRules.showsSaveButton(isDraftDirty: false))   // 未修改／儲存後
        #expect(TranscriptViewRules.showsSaveButton(isDraftDirty: true))     // 修改後
    }
}
