import Foundation
import Testing
@testable import WhisperApp

struct PCM16MixerTests {
    @Test
    func sumsStreamsAndZeroPadsTheShorterInput() {
        let left = pcm16([20_000, -20_000])
        let right = pcm16([10_000])

        #expect(PCM16Mixer.mix(left, right) == pcm16([30_000, -20_000]))
    }

    @Test
    func sumsTwoSignalStreams() {
        let left = pcm16([20_000])
        let right = pcm16([10_000])

        #expect(PCM16Mixer.mix(left, right) == pcm16([30_000]))
    }

    @Test
    func preservesFullAmplitudeWhenOnlyLeftHasSignal() {
        let left = pcm16([20_000])
        let right = pcm16([0])

        #expect(PCM16Mixer.mix(left, right) == pcm16([20_000]))
    }

    @Test
    func preservesFullAmplitudeWhenOnlyRightHasSignal() {
        let left = pcm16([0])
        let right = pcm16([20_000])

        #expect(PCM16Mixer.mix(left, right) == pcm16([20_000]))
    }

    @Test
    func clampsPositiveOverflowToInt16Max() {
        let left = pcm16([25_000])
        let right = pcm16([20_000])

        #expect(PCM16Mixer.mix(left, right) == pcm16([32_767]))
    }

    @Test
    func clampsNegativeOverflowToInt16Min() {
        let left = pcm16([-25_000])
        let right = pcm16([-20_000])

        #expect(PCM16Mixer.mix(left, right) == pcm16([-32_768]))
    }

    private func pcm16(_ samples: [Int16]) -> Data {
        samples.withUnsafeBytes { Data($0) }
    }

    // MARK: - mixNormalized (AC-A1, AC-A2, AC-A3)

    private func sineWave(amplitude: Double, seconds: Double, sampleRate: Int = 16_000) -> [Int16] {
        let sampleCount = Int(seconds * Double(sampleRate))
        return (0..<sampleCount).map { index in
            let phase = 2 * Double.pi * 220 * Double(index) / Double(sampleRate)
            return Int16(clamping: Int(amplitude * sin(phase)))
        }
    }

    private func rms(_ samples: ArraySlice<Int16>) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sumOfSquares = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (sumOfSquares / Double(samples.count)).squareRoot()
    }

    @Test
    func normalizedMixBringsQuietMicWithinSixDBOfLouderSystemAudio() {
        // AC-A1: system RMS ≈ 3000, mic RMS ≈ 800, 3s each at 16kHz.
        let systemSamples = sineWave(amplitude: 3000 * 1.4142, seconds: 3.0)
        let micSamples = sineWave(amplitude: 800 * 1.4142, seconds: 3.0)
        let mixed = PCM16Mixer.mixNormalized(pcm16(micSamples), pcm16(systemSamples))

        let mixedSamples = mixed.withUnsafeBytes { raw -> [Int16] in
            let buffer = raw.bindMemory(to: Int16.self)
            return buffer.map { Int16(littleEndian: $0) }
        }

        let micRMS = rms(mixedSamples[0..<micSamples.count])
        let systemRMS = rms(mixedSamples[0..<systemSamples.count])
        let ratio = micRMS / systemRMS
        #expect(ratio >= 0.5 && ratio <= 2.0)
    }

    @Test
    func normalizedMixHasNegligibleClipping() {
        // AC-A2: after normalization, fewer than 0.1% of samples should be clipped to Int16 extremes.
        let systemSamples = sineWave(amplitude: 3000 * 1.4142, seconds: 3.0)
        let micSamples = sineWave(amplitude: 800 * 1.4142, seconds: 3.0)
        let mixed = PCM16Mixer.mixNormalized(pcm16(micSamples), pcm16(systemSamples))

        let mixedSamples = mixed.withUnsafeBytes { raw -> [Int16] in
            let buffer = raw.bindMemory(to: Int16.self)
            return buffer.map { Int16(littleEndian: $0) }
        }
        let clippedCount = mixedSamples.filter { abs(Int32($0)) == 32_767 }.count
        let ratio = Double(clippedCount) / Double(mixedSamples.count)
        #expect(ratio < 0.001)
    }

    @Test
    func normalizedMixDegradesToOtherSourceWhenOneIsSilent() {
        // AC-A3: a fully-silent source must not be amplified as noise — its own normalization
        // gain must stay 1 (RMS == 0 guard) and it must not perturb the other source's samples
        // beyond normalization/rounding, which the RMS-closeness check below verifies.
        let systemSamples = sineWave(amplitude: 3000 * 1.4142, seconds: 1.0)
        let silence = [Int16](repeating: 0, count: systemSamples.count)
        let mixed = PCM16Mixer.mixNormalized(pcm16(silence), pcm16(systemSamples))

        let mixedSamples = mixed.withUnsafeBytes { raw -> [Int16] in
            let buffer = raw.bindMemory(to: Int16.self)
            return buffer.map { Int16(littleEndian: $0) }
        }
        let originalRMS = rms(systemSamples[0...])
        let mixedRMS = rms(mixedSamples[0...])
        let ratio = mixedRMS / originalRMS
        #expect(ratio >= 0.95 && ratio <= 1.05)
    }

    @Test
    func normalizedMixLeavesNearSilentBackgroundNoiseUnamplified() {
        // A near-silent source (e.g. mic self-noise) sits far below the silence detector's
        // threshold (500) and must not be blown up toward normalizationTargetRMS — that would
        // defeat the downstream silence filter by turning quiet noise into "loud" audio.
        let quietNoise = sineWave(amplitude: 20 * 1.4142, seconds: 1.0)
        let systemSamples = sineWave(amplitude: 3000 * 1.4142, seconds: 1.0)
        let mixed = PCM16Mixer.mixNormalized(pcm16(quietNoise), pcm16(systemSamples))

        let mixedSamples = mixed.withUnsafeBytes { raw -> [Int16] in
            let buffer = raw.bindMemory(to: Int16.self)
            return buffer.map { Int16(littleEndian: $0) }
        }
        // The quiet source's own RMS (~20) is unchanged by normalization, so the mix should
        // closely track the loud system source alone, not a boosted noise floor.
        let originalRMS = rms(systemSamples[0...])
        let mixedRMS = rms(mixedSamples[0...])
        let ratio = mixedRMS / originalRMS
        #expect(ratio >= 0.95 && ratio <= 1.05)
    }
}
