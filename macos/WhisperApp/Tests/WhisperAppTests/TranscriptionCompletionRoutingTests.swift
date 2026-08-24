import Testing
@testable import WhisperApp

struct TranscriptionCompletionRoutingTests {
    @Test
    func returnsMatchingEntryIDWhenAudioPathAlreadyExists() {
        let existing = TranscriptionHistoryEntry(audioPath: "/tmp/a.wav", model: "base", language: nil, text: "hi")
        let other = TranscriptionHistoryEntry(audioPath: "/tmp/b.wav", model: "base", language: nil, text: "bye")
        let result = TranscriptionCompletionRouting.existingEntryID(forAudioPath: "/tmp/a.wav", in: [other, existing])
        #expect(result == existing.id)
    }

    @Test
    func returnsNilWhenNoEntryMatchesThatAudioPath() {
        let entry = TranscriptionHistoryEntry(audioPath: "/tmp/a.wav", model: "base", language: nil, text: "hi")
        let result = TranscriptionCompletionRouting.existingEntryID(forAudioPath: "/tmp/never-seen.wav", in: [entry])
        #expect(result == nil)
    }

    @Test
    func returnsNilForEmptyHistory() {
        let result = TranscriptionCompletionRouting.existingEntryID(forAudioPath: "/tmp/a.wav", in: [])
        #expect(result == nil)
    }
}
