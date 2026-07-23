import Foundation
import Testing
@testable import WhisperApp

struct AudioChunkSilenceDetectorTests {
    @Test
    func rootMeanSquareOfAllZeroSamplesIsZero() {
        let samples = Data(repeating: 0, count: 200)
        #expect(AudioChunkSilenceDetector.rootMeanSquare(ofPCM16LittleEndian: samples) == 0)
    }

    @Test
    func rootMeanSquareOfLoudSamplesIsHigh() {
        var samples = Data()
        for _ in 0..<100 {
            var value: Int16 = 20_000
            withUnsafeBytes(of: &value) { samples.append(contentsOf: $0) }
        }
        #expect(AudioChunkSilenceDetector.rootMeanSquare(ofPCM16LittleEndian: samples) == 20_000)
    }

    @Test
    func isSilentReturnsTrueForQuietFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("silence-detector-quiet-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        var data = Data(repeating: 0, count: 44)
        for _ in 0..<50 {
            var value: Int16 = 10
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        try data.write(to: url)
        #expect(AudioChunkSilenceDetector.isSilent(contentsOf: url))
    }

    @Test
    func isSilentReturnsFalseForLoudFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("silence-detector-loud-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        var data = Data(repeating: 0, count: 44)
        for _ in 0..<50 {
            var value: Int16 = 12_000
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        try data.write(to: url)
        #expect(!AudioChunkSilenceDetector.isSilent(contentsOf: url))
    }

    @Test
    func isSilentFailsOpenForMissingFile() throws {
        // A read failure must never be treated as silence: that would silently drop real
        // audio instead of sending it to the worker. AC-2.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("silence-detector-missing-\(UUID()).wav")
        #expect(!AudioChunkSilenceDetector.isSilent(contentsOf: url))
    }

    @Test
    func isSilentReturnsTrueForHeaderOnlyFile() throws {
        // Readable but zero PCM samples is legitimately empty audio, not a read failure.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("silence-detector-header-only-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(repeating: 0, count: 44).write(to: url)
        #expect(AudioChunkSilenceDetector.isSilent(contentsOf: url))
    }

    @Test
    func durationSecondsMatchesActualPCMByteCountNotAFixedInterval() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("silence-detector-duration-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        var data = Data(repeating: 0, count: 44)
        // 8,000 samples at 16kHz mono = 0.5s of audio, well short of a 15s rotation interval.
        for _ in 0..<8_000 {
            var value: Int16 = 5
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        try data.write(to: url)
        #expect(AudioChunkSilenceDetector.durationSeconds(contentsOf: url) == 0.5)
    }

    @Test
    func durationSecondsIsZeroForMissingFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("silence-detector-duration-missing-\(UUID()).wav")
        #expect(AudioChunkSilenceDetector.durationSeconds(contentsOf: url) == 0)
    }
}
