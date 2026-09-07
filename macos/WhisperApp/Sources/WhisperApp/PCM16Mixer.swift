import Foundation

enum PCM16Mixer {
    /// Common RMS level each source is normalized toward before summing, so a quiet microphone
    /// isn't permanently drowned out by a louder system-audio stream. Chosen to sit well below
    /// Int16 headroom so two normalized-then-summed streams have room before clamping.
    static let normalizationTargetRMS: Double = 3000

    static func mix(_ first: Data, _ second: Data) -> Data {
        let sampleCount = max(first.count, second.count) / MemoryLayout<Int16>.size
        // Single withUnsafeBytes/withUnsafeMutableBytes pass over each buffer rather than one
        // closure invocation per sample (via the sample(at:in:) helper below) — behaviorally
        // identical, but the per-sample closure overhead is prohibitive at chunk-sized sample
        // counts (hundreds of thousands of samples per mixed chunk).
        var output = Data(count: sampleCount * MemoryLayout<Int16>.size)
        first.withUnsafeBytes { (leftRaw: UnsafeRawBufferPointer) in
            second.withUnsafeBytes { (rightRaw: UnsafeRawBufferPointer) in
                output.withUnsafeMutableBytes { (outRaw: UnsafeMutableRawBufferPointer) in
                    for index in 0..<sampleCount {
                        let left = loadSample(at: index, from: leftRaw)
                        let right = loadSample(at: index, from: rightRaw)
                        let mixed = Int16(clamping: Int32(left) + Int32(right)).littleEndian
                        outRaw.storeBytes(of: mixed, toByteOffset: index * 2, as: Int16.self)
                    }
                }
            }
        }
        return output
    }

    private static func loadSample(at index: Int, from raw: UnsafeRawBufferPointer) -> Int16 {
        let offset = index * MemoryLayout<Int16>.size
        guard offset + MemoryLayout<Int16>.size <= raw.count else { return 0 }
        return Int16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: Int16.self))
    }

    /// RMS floor below which a source is left unscaled rather than normalized. Without this, a
    /// near-silent source (mic self-noise, faint room tone — RMS far under
    /// `AudioChunkSilenceDetector.defaultThreshold`) would get amplified by a huge gain factor to
    /// reach `normalizationTargetRMS`, defeating the silence filter downstream and turning
    /// background noise into what looks like non-silent speech. Set comfortably below the
    /// silence threshold so genuinely quiet capture is never mistaken for a signal worth balancing.
    static let normalizationMinimumRMS: Double = 100

    /// Normalizes each source to `normalizationTargetRMS` (computed over the whole buffer), then
    /// mixes with the existing sum + clamp behavior. A silent or near-silent source (RMS below
    /// `normalizationMinimumRMS`, including RMS == 0) is left unscaled — there's no real signal to
    /// normalize, and scaling it up would otherwise amplify noise, per AC-A3.
    static func mixNormalized(_ first: Data, _ second: Data) -> Data {
        mix(normalized(first), normalized(second))
    }

    private static func normalized(_ data: Data) -> Data {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return data }

        // Single withUnsafeBytes pass over the whole buffer: calling sample(at:in:) per index
        // here (one withUnsafeBytes closure invocation per sample) is prohibitively slow at
        // chunk-sized sample counts (hundreds of thousands of samples per mixed chunk).
        var samples = [Int16](repeating: 0, count: sampleCount)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for index in 0..<sampleCount {
                samples[index] = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))
            }
        }

        var sumOfSquares: Double = 0
        for value in samples {
            let doubleValue = Double(value)
            sumOfSquares += doubleValue * doubleValue
        }
        let rms = (sumOfSquares / Double(sampleCount)).squareRoot()
        guard rms >= normalizationMinimumRMS else { return data }

        let gain = normalizationTargetRMS / rms
        var output = Data(count: data.count)
        output.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            for index in 0..<sampleCount {
                let scaled = Double(samples[index]) * gain
                let clamped = Int16(clamping: Int64(scaled.rounded())).littleEndian
                raw.storeBytes(of: clamped, toByteOffset: index * 2, as: Int16.self)
            }
        }
        return output
    }

    private static func sample(at index: Int, in data: Data) -> Int16 {
        let offset = index * MemoryLayout<Int16>.size
        guard offset + MemoryLayout<Int16>.size <= data.count else { return 0 }
        return data.withUnsafeBytes {
            Int16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: Int16.self))
        }
    }
}
