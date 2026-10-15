import Foundation
import Testing
@testable import WhisperApp

struct SwitchGuardRulesTests {
    // AC-1
    @Test func confirmOnlyForDirtyDraftAndDifferentTarget() {
        let current = UUID(), other = UUID()
        #expect(SwitchGuardRules.needsConfirmation(isDraftDirty: true, currentID: current, targetID: other))
        #expect(!SwitchGuardRules.needsConfirmation(isDraftDirty: false, currentID: current, targetID: other))
        #expect(!SwitchGuardRules.needsConfirmation(isDraftDirty: true, currentID: current, targetID: current))
        #expect(SwitchGuardRules.needsConfirmation(isDraftDirty: true, currentID: nil, targetID: other))  // 未存的暫存紀錄也保護
    }

    // AC-3
    @Test func choicesDecideWhetherToSwitch() {
        #expect(SwitchGuardRules.shouldSwitch(after: .saveAndSwitch, saveSucceeded: true))
        #expect(!SwitchGuardRules.shouldSwitch(after: .saveAndSwitch, saveSucceeded: false))   // 儲存失敗留在原紀錄
        #expect(SwitchGuardRules.shouldSwitch(after: .discardAndSwitch, saveSucceeded: false))
        #expect(!SwitchGuardRules.shouldSwitch(after: .cancel, saveSucceeded: true))
    }

    @Test func dialogWording() {
        #expect(SwitchGuardRules.title == "逐字稿有未儲存的修改")
        #expect(SwitchGuardRules.message == "切換到其他會議前要儲存嗎？")
    }
}
