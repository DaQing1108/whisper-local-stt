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
}
