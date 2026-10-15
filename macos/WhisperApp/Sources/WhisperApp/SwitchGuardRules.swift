import Foundation

/// Confirmation before the user switches away from a transcript with unsaved edits.
enum SwitchGuardRules {
    static let title = "逐字稿有未儲存的修改"
    static let message = "切換到其他會議前要儲存嗎？"

    static func needsConfirmation(isDraftDirty: Bool, currentID: UUID?, targetID: UUID) -> Bool {
        isDraftDirty && currentID != targetID
    }

    enum Choice: Equatable {
        case saveAndSwitch
        case discardAndSwitch
        case cancel
    }

    /// Whether to switch after the user's choice. `saveSucceeded` is read after `saveDraft()`:
    /// it clears `isDraftDirty` only on success, so a draft still dirty means the save failed.
    static func shouldSwitch(after choice: Choice, saveSucceeded: Bool) -> Bool {
        switch choice {
        case .saveAndSwitch: saveSucceeded
        case .discardAndSwitch: true
        case .cancel: false
        }
    }
}

/// A switch waiting for the user's answer.
struct PendingRecordSwitch: Identifiable {
    let entry: TranscriptionHistoryEntry
    /// 「載入結果」also moves to the 錄製 page — only once the switch actually happens.
    let showsCapturePage: Bool
    var id: UUID { entry.id }
}
