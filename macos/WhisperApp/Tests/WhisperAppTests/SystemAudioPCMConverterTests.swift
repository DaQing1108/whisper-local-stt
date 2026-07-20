@preconcurrency import AVFoundation
import Testing
@testable import WhisperApp

struct SystemAudioPCMConverterTests {
    @Test
    func converts48kHzStereoFloatTo16kHzMonoInt16PCM() throws {
        let inputFormat = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ))
        let input = try #require(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 480))
        input.frameLength = 480
        let channels = try #require(input.floatChannelData)
        for index in 0..<480 {
            channels[0][index] = 0.5
            channels[1][index] = -0.5
        }

        let converted = try SystemAudioPCMConverter.convert(input)
        let data = try #require(converted)

        #expect((300...322).contains(data.count))
        #expect(data.count.isMultiple(of: 2))
        #expect(data.contains { $0 != 0 })
    }
}
