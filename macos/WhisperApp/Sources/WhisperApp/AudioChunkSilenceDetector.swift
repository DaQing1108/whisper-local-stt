import Foundation

/// Detects near-silent 16kHz mono 16-bit PCM WAV chunks so they can be skipped
/// before being sent to the Whisper worker, avoiding hallucinated transcriptions.
enum AudioChunkSilenceDetector {
    static let defaultThreshold: Double = 500

    static func isSilent(contentsOf url: URL, threshold: Double = defaultThreshold) -> Bool {
        guard let data = try? Data(contentsOf: url), data.count > 44 else { return true }
        return rootMeanSquare(ofPCM16LittleEndian: data.suffix(from: 44)) < threshold
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
