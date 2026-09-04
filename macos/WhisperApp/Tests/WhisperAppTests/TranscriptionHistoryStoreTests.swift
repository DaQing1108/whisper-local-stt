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
    func updateResultIsNoOpWhenEntryWasDeleted() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let store = TranscriptionHistoryStore(fileURL: url)
        let audio = directory.appendingPathComponent("meeting.wav")
        let entry = try store.recordCompleted(audioURL: audio, model: "base", language: "zh", text: "會議完成")

        try store.remove(entry)
        #expect(store.entries.isEmpty)

        let result = try store.updateResult(id: entry.id, text: "重新轉錄後的文字", segments: [], durationSeconds: nil)
        #expect(result == nil)
        #expect(store.entries.isEmpty)

        let restored = TranscriptionHistoryStore(fileURL: url)
        #expect(restored.entries.isEmpty)
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

    // MARK: - Pre-change backup snapshots (transcript overwrite guard)

    private func backupFiles(in directory: URL, entryID: UUID) -> [URL] {
        let dir = directory.appendingPathComponent("history-backups/\(entryID.uuidString)", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .sorted { ($0.deletingPathExtension().lastPathComponent) < ($1.deletingPathExtension().lastPathComponent) }
    }

    @Test("updateResult and updateText snapshot the pre-overwrite entry before mutating")
    func backupCapturesPreOverwriteValues() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let store = TranscriptionHistoryStore(fileURL: url)
        let entry = try store.recordCompleted(
            audioURL: directory.appendingPathComponent("meeting.wav"),
            model: "base", language: "zh", text: "原始完整逐字稿內容",
            segments: [.init(start: 0, end: 3, text: "原始完整逐字稿內容")], durationSeconds: 3
        )

        _ = try store.updateResult(id: entry.id, text: "殘缺短版", segments: [], durationSeconds: 1)

        let afterResult = backupFiles(in: directory, entryID: entry.id)
        #expect(afterResult.count == 1)
        let snap1 = try JSONDecoder().decode(
            TranscriptionHistoryEntry.self, from: Data(contentsOf: afterResult[0])
        )
        #expect(snap1.text == "原始完整逐字稿內容")
        #expect(snap1.segments == entry.segments)
        #expect(snap1.durationSeconds == 3)

        Thread.sleep(forTimeInterval: 0.003)
        try store.updateText(id: entry.id, text: "又被改一次")
        let afterText = backupFiles(in: directory, entryID: entry.id)
        #expect(afterText.count == 2)
        let snap2 = try JSONDecoder().decode(
            TranscriptionHistoryEntry.self, from: Data(contentsOf: afterText[1])
        )
        #expect(snap2.text == "殘缺短版")
    }

    @Test("latestBackup returns the most recent pre-change snapshot")
    func latestBackupReadsNewestSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let store = TranscriptionHistoryStore(fileURL: url)
        let entry = try store.recordCompleted(
            audioURL: directory.appendingPathComponent("m.wav"),
            model: "base", language: "zh", text: "v1"
        )

        #expect(store.latestBackup(for: entry.id) == nil)

        try store.updateText(id: entry.id, text: "v2")
        Thread.sleep(forTimeInterval: 0.003)
        try store.updateText(id: entry.id, text: "v3")

        let latest = try #require(store.latestBackup(for: entry.id))
        #expect(latest.text == "v2")
        #expect(latest.id == entry.id)
    }

    @Test("Backup directory keeps only the newest 5 snapshots after 7 updates")
    func backupRotationKeepsNewestFive() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let store = TranscriptionHistoryStore(fileURL: url)
        let entry = try store.recordCompleted(
            audioURL: directory.appendingPathComponent("m.wav"),
            model: "base", language: "zh", text: "gen-0"
        )

        for generation in 1...7 {
            try store.updateText(id: entry.id, text: "gen-\(generation)")
            Thread.sleep(forTimeInterval: 0.003)
        }

        let files = backupFiles(in: directory, entryID: entry.id)
        #expect(files.count == 5)
        let texts = try files.map {
            try JSONDecoder().decode(TranscriptionHistoryEntry.self, from: Data(contentsOf: $0)).text
        }
        // 7 updates snapshot the OLD text each time: gen-0 .. gen-6. Newest 5 kept.
        #expect(texts == ["gen-2", "gen-3", "gen-4", "gen-5", "gen-6"])
    }

    @Test("updateText/updateResult still succeed when the backup directory cannot be created")
    func backupFailureNeverBlocksMainPersist() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let store = TranscriptionHistoryStore(fileURL: url)
        let entry = try store.recordCompleted(
            audioURL: directory.appendingPathComponent("m.wav"),
            model: "base", language: "zh", text: "original"
        )
        // Occupy the backup root path with a plain file so directory creation fails.
        try Data("blocker".utf8).write(to: directory.appendingPathComponent("history-backups"))

        try store.updateText(id: entry.id, text: "edited-text")
        _ = try store.updateResult(id: entry.id, text: "retranscribed", segments: [], durationSeconds: 2)

        let restored = TranscriptionHistoryStore(fileURL: url)
        #expect(restored.entries.count == 1)
        #expect(restored.entries[0].text == "retranscribed")
        #expect(restored.entries[0].durationSeconds == 2)
        #expect(store.latestBackup(for: entry.id) == nil)
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
