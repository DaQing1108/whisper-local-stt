import Foundation

/// Decides whether a completed transcription belongs to an existing history
/// entry (re-transcribing it, e.g. via "重新轉錄") or is a brand-new recording.
///
/// `WhisperApp.swift`'s `transcriptionCompletedHandler` and
/// `ContentView.showLatestWorkerResultIfNeeded()` are two independent
/// completion listeners that both fire on every worker completion. The
/// `ContentView` side already tracks a `retranscribeTargetEntryID` for the
/// specific case it started, but the `WhisperApp.swift` handler has no such
/// state — it used to unconditionally call `recordCompleted`, which created a
/// brand-new duplicate history entry every time a re-transcribe completed
/// (since mixed/live recording never "owns" that chunk). Matching by
/// `audioPath` against existing entries lets that handler tell the two cases
/// apart without needing to share UI state.
enum TranscriptionCompletionRouting {
    /// Returns the id of the history entry whose `audioPath` matches
    /// `audioPath`, if one exists — meaning this completion should update that
    /// entry in place rather than create a new one.
    static func existingEntryID(forAudioPath audioPath: String, in entries: [TranscriptionHistoryEntry]) -> UUID? {
        entries.first { $0.audioPath == audioPath }?.id
    }
}
