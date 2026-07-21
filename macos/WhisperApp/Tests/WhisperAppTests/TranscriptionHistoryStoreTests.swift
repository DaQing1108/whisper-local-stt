import Foundation
import Testing
@testable import WhisperApp

@MainActor
struct TranscriptionHistoryStoreTests {
    @Test
    func atomicallyPersistsAndRestoresCompletedEntry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let store = TranscriptionHistoryStore(fileURL: url)
        let audio = directory.appendingPathComponent("meeting.wav")

        try store.recordCompleted(audioURL: audio, model: "base", language: "zh", text: "會議完成")

        let restored = TranscriptionHistoryStore(fileURL: url)
        #expect(restored.entries.count == 1)
        #expect(restored.entries[0].audioPath == audio.path)
        #expect(restored.entries[0].text == "會議完成")
        #expect(restored.entries[0].model == "base")
    }

    @Test
    func updateResultPreservesObsidianNotePathAndUpdateObsidianNotePathPersists() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let store = TranscriptionHistoryStore(fileURL: url)
        let audio = directory.appendingPathComponent("meeting.wav")
        let entry = try store.recordCompleted(audioURL: audio, model: "base", language: "zh", text: "會議完成")

        try store.updateObsidianNotePath(id: entry.id, path: "/Vault/note.md")
        #expect(store.entries[0].obsidianNotePath == "/Vault/note.md")

        _ = try store.updateResult(id: entry.id, text: "更新後文字", segments: [], durationSeconds: nil)
        #expect(store.entries[0].obsidianNotePath == "/Vault/note.md")

        let restored = TranscriptionHistoryStore(fileURL: url)
        #expect(restored.entries[0].obsidianNotePath == "/Vault/note.md")
    }

    @Test
    func updateResultPreservesNotionChildPageIDAndUpdateNotionChildPageIDPersists() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let store = TranscriptionHistoryStore(fileURL: url)
        let audio = directory.appendingPathComponent("meeting.wav")
        let entry = try store.recordCompleted(audioURL: audio, model: "base", language: "zh", text: "會議完成")

        try store.updateNotionChildPageID(id: entry.id, pageID: "notion-page-id")
        #expect(store.entries[0].notionChildPageID == "notion-page-id")

        _ = try store.updateResult(id: entry.id, text: "更新後文字", segments: [], durationSeconds: nil)
        #expect(store.entries[0].notionChildPageID == "notion-page-id")

        let restored = TranscriptionHistoryStore(fileURL: url)
        #expect(restored.entries[0].notionChildPageID == "notion-page-id")
    }

    @Test
    func corruptHistoryIsReportedWithoutInventingEntries() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID()).json")
        try Data("not-json".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let store = TranscriptionHistoryStore(fileURL: url)

        #expect(store.entries.isEmpty)
        #expect(store.loadError != nil)
    }

    @Test
    func decodesLegacyEntryWithSafeRichResultDefaults() throws {
        let entry = TranscriptionHistoryEntry(
            id: UUID(), completedAt: Date(), audioPath: "/tmp/legacy.wav",
            model: "base", language: nil, text: "legacy"
        )
        let encoded = try JSONEncoder().encode(entry)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "segments")
        object.removeValue(forKey: "durationSeconds")
        object.removeValue(forKey: "domain")
        object.removeValue(forKey: "extraTerms")
        object.removeValue(forKey: "obsidianNotePath")
        object.removeValue(forKey: "notionChildPageID")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(TranscriptionHistoryEntry.self, from: legacy)

        #expect(decoded.segments.isEmpty)
        #expect(decoded.durationSeconds == nil)
        #expect(decoded.domain == "general")
        #expect(decoded.extraTerms.isEmpty)
        #expect(decoded.obsidianNotePath == nil)
        #expect(decoded.notionChildPageID == nil)
    }

    @Test
    func persistsEditedTextWithoutChangingResultMetadata() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let store = TranscriptionHistoryStore(fileURL: url)
        let entry = try store.recordCompleted(
            audioURL: directory.appendingPathComponent("meeting.wav"),
            model: "small", language: "zh", text: "before",
            segments: [.init(start: 0, end: 1, text: "before")], durationSeconds: 1,
            domain: "business", extraTerms: "VIA"
        )

        try store.updateText(id: entry.id, text: "after")
        let restored = TranscriptionHistoryStore(fileURL: url).entries[0]
        #expect(restored.text == "after")
        #expect(restored.segments == entry.segments)
        #expect(restored.domain == "business")
    }

    @Test
    func updatesAndPersistsOneCumulativeSystemAudioResult() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let store = TranscriptionHistoryStore(fileURL: url)
        let entry = try store.recordCompleted(
            audioURL: directory.appendingPathComponent("system-1.wav"),
            model: "base", language: "zh", text: "[00:00:00] 第一段",
            segments: [.init(start: 0, end: 15, text: "第一段")], durationSeconds: 15
        )

        _ = try store.updateResult(
            id: entry.id,
            text: "[00:00:00] 第一段\n[00:00:15] 第二段",
            segments: [
                .init(start: 0, end: 15, text: "第一段"),
                .init(start: 15, end: 20, text: "第二段")
            ],
            durationSeconds: 20,
            audioURL: directory.appendingPathComponent("system-session.wav")
        )

        let restored = try #require(TranscriptionHistoryStore(fileURL: url).entries.first)
        #expect(restored.id == entry.id)
        #expect(restored.text.contains("[00:00:15] 第二段"))
        #expect(restored.segments.count == 2)
        #expect(restored.durationSeconds == 20)
        #expect(restored.audioPath.hasSuffix("system-session.wav"))
    }

    @Test
    func fullStoreRestoresTrimmedEntryWhenAtomicWriteFails() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent("history", isDirectory: true)
        let url = directory.appendingPathComponent("history.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TranscriptionHistoryStore(fileURL: url, maximumEntries: 1)
        try store.recordCompleted(
            audioURL: root.appendingPathComponent("first.wav"),
            model: "base", language: nil, text: "first"
        )
        try FileManager.default.removeItem(at: directory)
        try Data("blocks-directory".utf8).write(to: directory)

        #expect(throws: (any Error).self) {
            try store.recordCompleted(
                audioURL: root.appendingPathComponent("second.wav"),
                model: "small", language: nil, text: "second"
            )
        }

        #expect(store.entries.count == 1)
        #expect(store.entries[0].text == "first")
        #expect(store.writeError != nil)
    }

    @Test func retentionTrimAndClearAllPersistImmediately() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let store = TranscriptionHistoryStore(fileURL: url, maximumEntries: 5)
        for index in 0..<3 {
            try store.recordCompleted(
                audioURL: directory.appendingPathComponent("\(index).wav"),
                model: "base", language: nil, text: "\(index)"
            )
        }
        try store.updateMaximumEntries(2)
        #expect(TranscriptionHistoryStore(fileURL: url).entries.count == 2)
        try store.clearAll()
        #expect(TranscriptionHistoryStore(fileURL: url).entries.isEmpty)
    }
}
