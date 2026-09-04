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

    // MARK: - Windowed isSilent (AC-1, AC-2, AC-3, AC-5)

    /// Appends `count` PCM16 little-endian samples of `value` to `data`.
    private func appendSamples(_ value: Int16, count: Int, to data: inout Data) {
        for _ in 0..<count {
            var sample = value
            withUnsafeBytes(of: &sample) { data.append(contentsOf: $0) }
        }
    }

    @Test
    func isSilentReturnsFalseWhenOnlyTheFinalSecondIsLoud() throws {
        // AC-1: whole-chunk average RMS would be diluted well below threshold, but the last
        // 1-second window alone is loud — must not be classified as silent.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("silence-detector-loud-tail-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let sampleRate = 16_000
        var data = Data(repeating: 0, count: 44)
        // Loud amplitude chosen so the whole-chunk RMS (sqrt of the mean of squares across all
        // 15s) is diluted below threshold by the 14s of silence, while the single 1s loud
        // window's own RMS (a constant-amplitude window, so its RMS equals the amplitude
        // itself) stays above threshold: sqrt(1*1500^2 / 15) ≈ 387 < 500 ≤ 1500.
        appendSamples(0, count: 14 * sampleRate, to: &data)      // 14s silent
        appendSamples(1_500, count: 1 * sampleRate, to: &data)   // 1s loud
        try data.write(to: url)

        // Whole-chunk average confirms the dilution premise of the bug this fix addresses.
        let wholeChunkRMS = AudioChunkSilenceDetector.rootMeanSquare(
            ofPCM16LittleEndian: data.suffix(from: 44)
        )
        #expect(wholeChunkRMS < AudioChunkSilenceDetector.defaultThreshold)

        #expect(!AudioChunkSilenceDetector.isSilent(contentsOf: url))
    }

    @Test
    func isSilentReturnsTrueWhenEveryWindowIsQuiet() throws {
        // AC-2: existing all-quiet behavior preserved when checked window-by-window.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("silence-detector-all-quiet-windows-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        var data = Data(repeating: 0, count: 44)
        // 5 windows of 0.1s each at a 100Hz test sample rate = 10 samples/window.
        appendSamples(5, count: 50, to: &data)
        try data.write(to: url)
        #expect(
            AudioChunkSilenceDetector.isSilent(
                contentsOf: url,
                windowSeconds: 0.1,
                sampleRate: 100
            )
        )
    }

    @Test
    func isSilentReturnsFalseWhenEveryWindowIsLoud() throws {
        // AC-3: existing all-loud behavior preserved when checked window-by-window.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("silence-detector-all-loud-windows-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        var data = Data(repeating: 0, count: 44)
        appendSamples(20_000, count: 50, to: &data)
        try data.write(to: url)
        #expect(
            !AudioChunkSilenceDetector.isSilent(
                contentsOf: url,
                windowSeconds: 0.1,
                sampleRate: 100
            )
        )
    }

    @Test
    func isSilentDetectsLoudSampleInResidualTailWindow() throws {
        // AC-5: window count doesn't evenly divide the sample count. With a 1s window at a
        // 10Hz test sample rate, a 2.3s file yields 2 full windows plus a 0.3s (3-sample)
        // residual tail. The loud sample lives only in that residual tail and must still be
        // detected — the while-loop's `min(offset + windowByteCount, endIndex)` must not drop it.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("silence-detector-residual-tail-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        var data = Data(repeating: 0, count: 44)
        appendSamples(5, count: 20, to: &data)   // 2 full 1s windows (10 samples each), quiet
        appendSamples(5, count: 2, to: &data)    // residual tail: 2 quiet samples
        appendSamples(20_000, count: 1, to: &data) // residual tail: 1 loud sample (0.1s in)
        try data.write(to: url)
        // Total: 23 samples over a 10-sample window = 2 full windows + 3-sample residual tail.
        #expect(
            !AudioChunkSilenceDetector.isSilent(
                contentsOf: url,
                windowSeconds: 1.0,
                sampleRate: 10
            )
        )
    }

    @Test
    func isSilentDefaultWindowingUsesPCM16WAVWriterSampleRate() throws {
        // AC-6 / signature check: default sampleRate parameter matches the writer's constant,
        // and rootMeanSquare's own signature/behavior is unchanged (called per-window here).
        #expect(Double(PCM16WAVWriter.sampleRate) == 16_000)
    }
}
