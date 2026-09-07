import Foundation

/// Detects near-silent 16kHz mono 16-bit PCM WAV chunks so they can be skipped
/// before being sent to the Whisper worker, avoiding hallucinated transcriptions.
enum AudioChunkSilenceDetector {
    static let defaultThreshold: Double = 500

    /// Fails open (returns `false`, i.e. "not silent") when the file can't be read, so a
    /// transient I/O problem never causes real audio to be silently dropped without being
    /// sent to the worker. A file that reads successfully but contains no PCM samples past
    /// the WAV header is legitimately empty audio, not a read failure, and is treated as silent.
    static func isSilent(
        contentsOf url: URL,
        threshold: Double = defaultThreshold,
        windowSeconds: Double = 1.0,
        sampleRate: Double = Double(PCM16WAVWriter.sampleRate)
    ) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        guard data.count > 44 else { return true }
        let samples = data.suffix(from: 44)
        let windowByteCount = max(2, Int(windowSeconds * sampleRate) * 2)  // 2 bytes/sample (Int16)
        var offset = samples.startIndex
        while offset < samples.endIndex {
            let end = min(offset + windowByteCount, samples.endIndex)
            if rootMeanSquare(ofPCM16LittleEndian: samples[offset..<end]) >= threshold {
                return false
            }
            offset = end
        }
        return true
    }

    /// Actual audio duration of a finalized chunk, derived from its PCM byte count — not the
    /// nominal rotation interval, which overstates duration for partial/interrupted chunks.
    static func durationSeconds(contentsOf url: URL, sampleRate: Double = Double(PCM16WAVWriter.sampleRate)) -> Double {
        guard let data = try? Data(contentsOf: url), data.count > 44 else { return 0 }
        let sampleCount = (data.count - 44) / 2
        return Double(sampleCount) / sampleRate
    }

    /// Searches a window of raw PCM16-little-endian samples for the quietest sub-window
    /// ("energy valley"), so chunk rotation can align its cut point to a natural pause instead of
    /// slicing through the middle of a spoken word. Pure function over the given buffer: same
    /// input always yields the same byte offset (O(n) single pass over the windows).
    ///
    /// `searchWindowSeconds` sizes each candidate sub-window; the returned offset is the start of
    /// the quietest one, aligned to a 2-byte (Int16) sample boundary. Returns `nil` when `samples`
    /// is too short to contain even one full sub-window.
    ///
    /// Known limitation: candidate windows are non-overlapping (stepped by a full window each
    /// time), not a sliding window. A real silent gap that straddles two adjacent window
    /// boundaries gets its energy split across both, so neither window's RMS may register as low
    /// as the gap's true quietness — an acceptable approximation for this stopgap, not a
    /// correctness bug, but worth knowing if cut points look slightly off from the actual pause.
    static func findEnergyValley(
        in samples: Data,
        searchWindowSeconds: Double,
        sampleRate: Double = Double(PCM16WAVWriter.sampleRate)
    ) -> Int? {
        let windowByteCount = max(2, Int(searchWindowSeconds * sampleRate) * 2)
        guard samples.count >= windowByteCount else { return nil }

        let start = samples.startIndex
        var bestOffset: Int?
        var bestRMS = Double.greatestFiniteMagnitude
        var offset = start
        while offset + windowByteCount <= samples.endIndex {
            let window = samples[offset..<(offset + windowByteCount)]
            let windowRMS = rootMeanSquare(ofPCM16LittleEndian: window)
            if windowRMS < bestRMS {
                bestRMS = windowRMS
                bestOffset = offset - start
            }
            offset += windowByteCount
        }
        return bestOffset
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
