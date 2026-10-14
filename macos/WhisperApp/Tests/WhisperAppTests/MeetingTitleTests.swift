import Foundation
import Testing
@testable import WhisperApp

/// Meeting name saved on its own (before any AI summary), and what that name-only record does
/// downstream: summary generation, Obsidian export, history deletion.
@MainActor
struct MeetingTitleTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func titleWithoutSummaryPersistsAsEmptyRecord() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("summaries.json")
        let id = UUID()

        try MeetingSummaryStore(fileURL: url).saveTitle(transcriptionID: id, title: "產品週會")

        let restored = try #require(MeetingSummaryStore(fileURL: url).summary(for: id))
        #expect(restored.meetingTitle == "產品週會")
        #expect(restored.status == .empty)
        #expect(restored.generatedText.isEmpty && restored.editedText.isEmpty && restored.provider.isEmpty)
        #expect(restored.effectiveText.isEmpty)
    }

    @Test func renameUpdatesExistingSummaryWithoutTouchingContent() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingSummaryStore(fileURL: directory.appendingPathComponent("summaries.json"))
        let id = UUID()
        try store.begin(transcriptionID: id, title: "舊名稱", provider: "openai")
        try store.complete(transcriptionID: id, generatedText: "## 摘要\n內容", provider: "openai")

        try store.saveTitle(transcriptionID: id, title: "新名稱")

        let summary = try #require(store.summary(for: id))
        #expect(summary.meetingTitle == "新名稱")
        #expect(summary.status == .completed)
        #expect(summary.generatedText == "## 摘要\n內容")
        #expect(store.summaries.count == 1)
    }

    @Test func laterSummaryGenerationReusesNameOnlyRecord() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingSummaryStore(fileURL: directory.appendingPathComponent("summaries.json"))
        let entry = TranscriptionHistoryEntry(audioPath: "/tmp/a.wav", model: "base", language: "zh", text: "逐字稿")
        try store.saveTitle(transcriptionID: entry.id, title: "產品週會")
        let original = try #require(store.summary(for: entry.id))
        let controller = MeetingSummaryController(
            store: store, generators: [.openAI: FixedGenerator()], credentials: { _ in "key" }
        )

        // The UI passes the current (header) name when generating, as before.
        await controller.generate(for: entry, title: "產品週會", provider: .openAI)

        let summary = try #require(store.summary(for: entry.id))
        #expect(store.summaries.count == 1)
        #expect(summary.id == original.id && summary.meetingID == original.meetingID)
        #expect(summary.meetingTitle == "產品週會")
        #expect(summary.status == .completed)
        #expect(summary.generatedText == "## 摘要\n合成摘要")
    }

    @Test func obsidianNoteHandlesFullEmptyAndMissingSummary() throws {
        let vault = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: vault) }
        func note(title: String?, text: String = "", status: MeetingSummaryStatus = .empty) throws -> String {
            let entry = TranscriptionHistoryEntry(
                audioPath: "/tmp/\(UUID()).wav", model: "base", language: "zh", text: "合成逐字稿"
            )
            let summary = title.map {
                MeetingSummary(transcriptionID: entry.id, meetingTitle: $0, generatedText: text, status: status)
            }
            let output = try ObsidianExportService().export(entry, summary: summary, to: vault)
            return try String(contentsOf: output, encoding: .utf8)
        }

        let full = try note(title: "產品週會", text: "重點", status: .completed)
        #expect(full.contains("# 產品週會\n\n## AI 會議摘要\n\n重點\n\n## Source Transcript"))

        let nameOnly = try note(title: "產品週會")
        #expect(nameOnly.contains("# 產品週會\n\n## Source Transcript\n\n合成逐字稿"))
        #expect(!nameOnly.contains("## AI 會議摘要"))

        let none = try note(title: nil)
        #expect(none.contains("# Transcription\n\n合成逐字稿"))
        #expect(!none.contains("## AI 會議摘要"))
    }

    @Test func deletingHistoryEntryAlsoDeletesNameOnlyRecord() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "MeetingTitleTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = TranscriptionHistoryStore(fileURL: root.appendingPathComponent("history.json"))
        let entry = try history.recordCompleted(
            audioURL: root.appendingPathComponent("audio.wav"), model: "base", language: nil, text: "合成"
        )
        let summaries = MeetingSummaryStore(fileURL: root.appendingPathComponent("summaries.json"))
        try summaries.saveTitle(transcriptionID: entry.id, title: "只有名稱")
        let coordinator = HistoryDeletionCoordinator(
            history: history, summaries: summaries, settings: AppSettingsStore(defaults: defaults),
            tombstoneURL: root.appendingPathComponent("pending.json")
        )

        try coordinator.delete(entry)

        #expect(summaries.summary(for: entry.id) == nil)
        #expect(history.entries.isEmpty)
    }

    private struct FixedGenerator: MeetingSummaryGenerating {
        let providerName = "openai"
        func generate(transcript: String, apiKey: String) async throws -> String { "## 摘要\n合成摘要" }
    }
}
