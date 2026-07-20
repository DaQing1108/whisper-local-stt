import Foundation
import Testing
@testable import WhisperApp

@MainActor
struct HistoryDeletionCoordinatorTests {
    @Test func durableTombstoneAllowsRetryAfterPartialCascadeFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let historyURL = root.appendingPathComponent("history/history.json")
        let summaryDirectory = root.appendingPathComponent("summary", isDirectory: true)
        let summaryURL = summaryDirectory.appendingPathComponent("summary.json")
        let tombstoneURL = root.appendingPathComponent("coord/pending.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "HistoryDeletionCoordinatorTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettingsStore(defaults: defaults)
        let history = TranscriptionHistoryStore(fileURL: historyURL)
        let entry = try history.recordCompleted(
            audioURL: root.appendingPathComponent("audio.wav"),
            model: "base", language: nil, text: "sensitive transcript"
        )
        let summaries = MeetingSummaryStore(fileURL: summaryURL)
        try summaries.begin(transcriptionID: entry.id, title: "Sensitive", provider: "mock")
        settings.markNotionOutcomeAmbiguous(entryID: entry.id)
        let coordinator = HistoryDeletionCoordinator(
            history: history, summaries: summaries, settings: settings, tombstoneURL: tombstoneURL
        )
        try FileManager.default.removeItem(at: summaryDirectory)
        try Data("block-summary-directory".utf8).write(to: summaryDirectory)

        #expect(throws: (any Error).self) { try coordinator.delete(entry) }
        #expect(history.entries.isEmpty)
        #expect(coordinator.pendingDeletionIDs == Set([entry.id]))
        #expect(settings.isNotionOutcomeAmbiguous(entryID: entry.id))
        #expect(FileManager.default.fileExists(atPath: tombstoneURL.path))

        try FileManager.default.removeItem(at: summaryDirectory)
        try coordinator.reconcile()

        #expect(coordinator.pendingDeletionIDs.isEmpty)
        #expect(summaries.summary(for: entry.id) == nil)
        #expect(!settings.isNotionOutcomeAmbiguous(entryID: entry.id))
    }
}
