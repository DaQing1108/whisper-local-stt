import Foundation
import Testing
@testable import WhisperApp

struct RecordingArtifactCleanerTests {
    @Test
    func removesOnlyUnprotectedHeaderOnlyWAVFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("orphan-cleaner-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let orphan = directory.appendingPathComponent("orphan.wav")
        let protected = directory.appendingPathComponent("protected.wav")
        let audio = directory.appendingPathComponent("audio.wav")
        _ = try PCM16WAVWriter(url: orphan).finalize()
        _ = try PCM16WAVWriter(url: protected).finalize()
        let audioWriter = try PCM16WAVWriter(url: audio)
        try audioWriter.append(Data([0x01, 0x02]))
        _ = try audioWriter.finalize()

        let removed = try RecordingArtifactCleaner().removeEmptyOrphans(
            in: directory,
            protectedURLs: [protected]
        )

        #expect(removed.count == 1)
        #expect(removed.first?.lastPathComponent == orphan.lastPathComponent)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(FileManager.default.fileExists(atPath: protected.path))
        #expect(FileManager.default.fileExists(atPath: audio.path))
    }
}
