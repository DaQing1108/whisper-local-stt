import Testing
@testable import WhisperApp

struct TranscriptionExportServiceTests {
    private let entry = TranscriptionHistoryEntry(
        audioPath: "/tmp/meeting.wav", model: "base", language: "zh", text: "original",
        segments: [
            .init(start: 0.125, end: 1.5, text: "第一段"),
            .init(start: 61.001, end: 62.25, text: "第二段"),
        ]
    )

    @Test func textAndMarkdownUseEditedText() throws {
        #expect(try TranscriptionExportFormat.text.render(entry: entry, editedText: "edited") == "edited")
        #expect(try TranscriptionExportFormat.markdown.render(entry: entry, editedText: "edited").contains("edited"))
    }

    @Test func srtUsesRealSegmentTimestamps() throws {
        let output = try TranscriptionExportFormat.srt.render(entry: entry, editedText: "ignored")
        #expect(output.contains("00:00:00,125 --> 00:00:01,500"))
        #expect(output.contains("00:01:01,001 --> 00:01:02,250"))
    }

    @Test func timecodedTextUsesReadableSegmentStartTimes() throws {
        let output = try TranscriptionExportFormat.timecodedText.render(entry: entry, editedText: "ignored")
        #expect(output == "[00:00:00] 第一段\n[00:01:01] 第二段")
        #expect(TranscriptionExportFormat.timecodedText.filenameExtension == "txt")
    }

    @Test func srtRejectsMissingSegments() {
        let old = TranscriptionHistoryEntry(
            audioPath: "/tmp/old.wav", model: "base", language: nil, text: "old"
        )
        #expect(throws: TranscriptionExportError.missingSegments) {
            try TranscriptionExportFormat.srt.render(entry: old, editedText: "old")
        }
    }
}
