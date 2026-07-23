import Foundation

/// Detects near-silent 16kHz mono 16-bit PCM WAV chunks so they can be skipped
/// before being sent to the Whisper worker, avoiding hallucinated transcriptions.
enum AudioChunkSilenceDetector {
    static let defaultThreshold: Double = 500

    /// Fails open (returns `false`, i.e. "not silent") when the file can't be read, so a
    /// transient I/O problem never causes real audio to be silently dropped without being
    /// sent to the worker. A file that reads successfully but contains no PCM samples past
    /// the WAV header is legitimately empty audio, not a read failure, and is treated as silent.
    static func isSilent(contentsOf url: URL, threshold: Double = defaultThreshold) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        guard data.count > 44 else { return true }
        return rootMeanSquare(ofPCM16LittleEndian: data.suffix(from: 44)) < threshold
    }

    /// Actual audio duration of a finalized chunk, derived from its PCM byte count — not the
    /// nominal rotation interval, which overstates duration for partial/interrupted chunks.
    static func durationSeconds(contentsOf url: URL, sampleRate: Double = Double(PCM16WAVWriter.sampleRate)) -> Double {
        guard let data = try? Data(contentsOf: url), data.count > 44 else { return 0 }
        let sampleCount = (data.count - 44) / 2
        return Double(sampleCount) / sampleRate
    }

    static func rootMeanSquare(ofPCM16LittleEndian samples: Data) -> Double {
        guard samples.count >= 2 else { return 0 }
        var sumOfSquares: Double = 0
        var sampleCount = 0
        samples.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) in
            let count = rawBuffer.count / 2
            for index in 0..<count {
                let low = UInt16(rawBuffer[index * 2])
                let high = UInt16(rawBuffer[index * 2 + 1])
                let sample = Int16(bitPattern: low | (high << 8))
                sumOfSquares += Double(sample) * Double(sample)
            }
            sampleCount = count
        }
        guard sampleCount > 0 else { return 0 }
        return (sumOfSquares / Double(sampleCount)).squareRoot()
    }
}
