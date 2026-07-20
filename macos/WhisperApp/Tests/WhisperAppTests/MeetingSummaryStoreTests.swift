import Foundation
import Testing
@testable import WhisperApp

@MainActor
struct MeetingSummaryStoreTests {
    @Test func persistsGenerationCompletionAndExplicitEdit() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let transcriptionID = UUID()
        let store = MeetingSummaryStore(fileURL: fixture.fileURL)

        let started = try store.begin(
            transcriptionID: transcriptionID, title: "週會", provider: "mock"
        )
        #expect(started.status == .generating)
        try store.complete(transcriptionID: transcriptionID, generatedText: "原始摘要", provider: "mock")
        try store.saveEdit(transcriptionID: transcriptionID, title: "週會 v2", text: "編輯摘要")

        let restored = try #require(MeetingSummaryStore(fileURL: fixture.fileURL).summary(for: transcriptionID))
        #expect(restored.meetingID == started.meetingID)
        #expect(restored.status == .completed)
        #expect(restored.generatedText == "原始摘要")
        #expect(restored.editedText == "編輯摘要")
        #expect(restored.effectiveText == "編輯摘要")
        #expect(restored.meetingTitle == "週會 v2")
    }

    @Test func failureDoesNotRequireOrMutateTranscriptionHistory() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let transcriptionID = UUID()
        let store = MeetingSummaryStore(fileURL: fixture.fileURL)
        try store.begin(transcriptionID: transcriptionID, title: "訪談", provider: "mock")

        try store.fail(transcriptionID: transcriptionID, message: "provider unavailable")

        let summary = try #require(store.summary(for: transcriptionID))
        #expect(summary.status == .failed)
        #expect(summary.errorMessage == "provider unavailable")
        #expect(summary.generatedText.isEmpty)
    }

    @Test func editSavedDuringGenerationSurvivesCompletion() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let id = UUID()
        let store = MeetingSummaryStore(fileURL: fixture.fileURL)
        try store.begin(transcriptionID: id, title: "原標題", provider: "mock")
        try store.saveEdit(transcriptionID: id, title: "新標題", text: "使用者草稿")

        try store.complete(transcriptionID: id, generatedText: "模型輸出", provider: "mock")

        let summary = try #require(store.summary(for: id))
        #expect(summary.generatedText == "模型輸出")
        #expect(summary.editedText == "使用者草稿")
        #expect(summary.effectiveText == "使用者草稿")
        #expect(summary.meetingTitle == "新標題")
    }

    @Test func restartMarksInterruptedGenerationFailed() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let id = UUID()
        let store = MeetingSummaryStore(fileURL: fixture.fileURL)
        try store.begin(transcriptionID: id, title: "中斷會議", provider: "mock")

        let restored = try #require(MeetingSummaryStore(fileURL: fixture.fileURL).summary(for: id))

        #expect(restored.status == .failed)
        #expect(restored.errorMessage == "Summary generation was interrupted")
    }

    @Test func failedAtomicWriteRollsBackInMemoryEdit() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let transcriptionID = UUID()
        let store = MeetingSummaryStore(fileURL: fixture.fileURL)
        try store.begin(transcriptionID: transcriptionID, title: "會議", provider: "mock")
        try store.complete(transcriptionID: transcriptionID, generatedText: "stable", provider: "mock")
        try FileManager.default.removeItem(at: fixture.directory)
        try Data("block-directory".utf8).write(to: fixture.directory)

        #expect(throws: (any Error).self) {
            try store.saveEdit(transcriptionID: transcriptionID, title: "changed", text: "must rollback")
        }
        #expect(store.summary(for: transcriptionID)?.effectiveText == "stable")
        #expect(store.writeError != nil)
    }

    @Test func removesSummariesForDeletedHistoryIDs() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = UUID(), second = UUID()
        let store = MeetingSummaryStore(fileURL: fixture.fileURL)
        try store.begin(transcriptionID: first, title: "first", provider: "mock")
        try store.begin(transcriptionID: second, title: "second", provider: "mock")

        try store.remove(transcriptionIDs: Set([first]))

        let restored = MeetingSummaryStore(fileURL: fixture.fileURL)
        #expect(restored.summary(for: first) == nil)
        #expect(restored.summary(for: second) != nil)
    }

    private struct Fixture {
        let directory: URL
        let fileURL: URL
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            fileURL = directory.appendingPathComponent("summaries.json")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        func cleanup() { try? FileManager.default.removeItem(at: directory) }
    }
}
