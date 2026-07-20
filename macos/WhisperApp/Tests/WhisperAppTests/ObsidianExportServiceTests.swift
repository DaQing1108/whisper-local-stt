import Foundation
import Testing
@testable import WhisperApp

struct ObsidianExportServiceTests {
    @Test
    func validatesExistingDirectoryAndAtomicallyExportsMarkdownInsideIt() throws {
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }
        let service = ObsidianExportService(now: { Date(timeIntervalSince1970: 0) })
        let entry = TranscriptionHistoryEntry(
            id: UUID(), completedAt: Date(timeIntervalSince1970: 0),
            audioPath: "/tmp/../tmp/meeting:name.wav", model: "base",
            language: "zh", text: "逐字稿內容"
        )

        #expect(try service.validateVault(vault) == vault.standardizedFileURL)
        let output = try service.export(entry, to: vault)

        #expect(output.deletingLastPathComponent() == vault.standardizedFileURL)
        #expect(output.pathExtension == "md")
        #expect(!output.lastPathComponent.contains(":"))
        let markdown = try String(contentsOf: output, encoding: .utf8)
        #expect(markdown.contains("source: whisper-swiftui"))
        #expect(markdown.contains("逐字稿內容"))
        #expect(markdown.contains("model: \"base\""))
    }

    @Test
    func rejectsMissingPathAndRegularFileAsVault() throws {
        let service = ObsidianExportService()
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(throws: ObsidianExportError.invalidVault) { try service.validateVault(missing) }

        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(throws: ObsidianExportError.invalidVault) { try service.validateVault(file) }
    }

    @Test
    func meetingNoteKeepsEffectiveSummaryAndSourceTranscriptSeparate() throws {
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }
        let entry = TranscriptionHistoryEntry(
            audioPath: "/tmp/meeting.wav", model: "base", language: "zh", text: "source transcript"
        )
        let summary = MeetingSummary(
            transcriptionID: entry.id, meetingTitle: "週會",
            generatedText: "generated", editedText: "edited", provider: "openai", status: .completed
        )

        let output = try ObsidianExportService().export(entry, summary: summary, to: vault)
        let markdown = try String(contentsOf: output, encoding: .utf8)
        #expect(markdown.contains("# 週會"))
        #expect(markdown.contains("## AI 會議摘要\n\nedited"))
        #expect(markdown.contains("## Source Transcript\n\nsource transcript"))
        #expect(markdown.contains(summary.meetingID.uuidString))
    }

    @Test
    func repeatedPublishNeverOverwritesExistingMeetingNote() throws {
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }
        let service = ObsidianExportService(now: { Date(timeIntervalSince1970: 0) })
        let entry = TranscriptionHistoryEntry(
            audioPath: "/tmp/meeting.wav", model: "base", language: nil, text: "first"
        )
        let first = try service.export(entry, to: vault)
        let original = try Data(contentsOf: first)

        let second = try service.export(entry, to: vault)

        #expect(first != second)
        #expect(try Data(contentsOf: first) == original)
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    @Test
    func republishingWithExistingPathOverwritesTheSameNoteInPlace() throws {
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }
        let service = ObsidianExportService(now: { Date(timeIntervalSince1970: 0) })
        let entry = TranscriptionHistoryEntry(
            audioPath: "/tmp/meeting.wav", model: "base", language: nil, text: "first version"
        )
        let firstOutput = try service.export(entry, summary: nil, existingPath: nil, to: vault)

        var republished = entry
        republished.text = "second version"
        let secondOutput = try service.export(
            republished, summary: nil, existingPath: firstOutput, to: vault
        )

        #expect(secondOutput == firstOutput)
        #expect(try FileManager.default.contentsOfDirectory(atPath: vault.path).count == 1)
        let markdown = try String(contentsOf: secondOutput, encoding: .utf8)
        #expect(markdown.contains("second version"))
        #expect(!markdown.contains("first version"))
    }

    @Test
    func existingPathOutsideVaultFallsBackToCreatingANewNote() throws {
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }
        let outsidePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-\(UUID().uuidString).md")
        let service = ObsidianExportService()
        let entry = TranscriptionHistoryEntry(
            audioPath: "/tmp/meeting.wav", model: "base", language: nil, text: "content"
        )

        let output = try service.export(entry, summary: nil, existingPath: outsidePath, to: vault)

        #expect(output.deletingLastPathComponent() == vault.standardizedFileURL)
        #expect(!FileManager.default.fileExists(atPath: outsidePath.path))
    }

    @Test
    func segmentsArePreservedAsTimecodedLinesWhenPresent() throws {
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }
        let entry = TranscriptionHistoryEntry(
            audioPath: "/tmp/meeting.wav", model: "base", language: nil, text: "fallback text",
            segments: [
                TranscriptionSegment(start: 0, end: 2, text: "第一段"),
                TranscriptionSegment(start: 65, end: 70, text: "第二段"),
            ]
        )

        let output = try ObsidianExportService().export(entry, to: vault)

        let markdown = try String(contentsOf: output, encoding: .utf8)
        #expect(markdown.contains("[00:00] 第一段"))
        #expect(markdown.contains("[01:05] 第二段"))
        #expect(!markdown.contains("fallback text"))
    }

    @Test
    func existingPathInsideVaultSubfolderIsRecognizedAndOverwritten() throws {
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let subfolder = vault.appendingPathComponent("Meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }
        let notePath = subfolder.appendingPathComponent("existing-note.md")
        try Data("old content".utf8).write(to: notePath)
        let service = ObsidianExportService()
        let entry = TranscriptionHistoryEntry(
            audioPath: "/tmp/meeting.wav", model: "base", language: nil, text: "new content"
        )

        let output = try service.export(entry, summary: nil, existingPath: notePath, to: vault)

        #expect(output == notePath)
        let markdown = try String(contentsOf: output, encoding: .utf8)
        #expect(markdown.contains("new content"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: vault.path) == ["Meetings"])
    }

    @Test
    func rejectsSymlinkVaultWithoutWritingIntoItsTarget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        let link = root.appendingPathComponent("vault-link", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ObsidianExportService()
        let entry = TranscriptionHistoryEntry(
            id: UUID(), completedAt: Date(), audioPath: "/tmp/audio.wav",
            model: "base", language: nil, text: "must not escape"
        )

        #expect(throws: ObsidianExportError.invalidVault) { try service.export(entry, to: link) }
        #expect((try FileManager.default.contentsOfDirectory(atPath: outside.path)).isEmpty)
    }
}
