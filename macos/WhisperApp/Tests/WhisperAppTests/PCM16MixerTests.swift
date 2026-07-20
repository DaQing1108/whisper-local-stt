import Foundation
import Testing
@testable import WhisperApp

struct PCM16MixerTests {
    @Test
    func averagesStreamsAndZeroPadsTheShorterInput() {
        let left = pcm16([20_000, -20_000])
        let right = pcm16([10_000])

        #expect(PCM16Mixer.mix(left, right) == pcm16([15_000, -10_000]))
    }

    private func pcm16(_ samples: [Int16]) -> Data {
        samples.withUnsafeBytes { Data($0) }
    }
}
