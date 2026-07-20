@preconcurrency import AVFoundation
import Foundation

enum SystemAudioPCMConverter {
    private static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: Double(PCM16WAVWriter.sampleRate),
        channels: AVAudioChannelCount(PCM16WAVWriter.channelCount),
        interleaved: true
    )!

    static func convert(_ buffer: AVAudioPCMBuffer) throws -> Data? {
        guard let converter = AVAudioConverter(from: buffer.format, to: outputFormat) else {
            throw AudioCaptureError.converterUnavailable
        }
        return try AVAudioEngineCaptureBackend.convert(buffer, with: converter, to: outputFormat)
    }
}
