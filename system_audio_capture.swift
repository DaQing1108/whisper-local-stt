// system_audio_capture.swift
// Captures system audio via ScreenCaptureKit and streams raw 16kHz mono int16 PCM to stdout.
// Python reads stdout, wraps in WAV, and sends to Whisper.
//
// Compile:
//   swiftc system_audio_capture.swift -o bin/system_audio_capture \
//     -framework ScreenCaptureKit -framework AVFoundation -framework CoreMedia
// Sign:
//   codesign --sign - --entitlements tools/entitlements.plist --force bin/system_audio_capture

import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

private let TARGET_RATE: Double = 16000
private let TARGET_FORMAT = AVAudioFormat(
    commonFormat: .pcmFormatInt16, sampleRate: TARGET_RATE, channels: 1, interleaved: true
)!

class AudioStreamer: NSObject, SCStreamOutput, SCStreamDelegate {
    var stream: SCStream?
    private var converter: AVAudioConverter?
    private var lastInputFormat: AVAudioFormat?
    private let outputHandle = FileHandle.standardOutput

    func start() async throws {
        // onScreenWindowsOnly:false ensures background processes (browser audio renderers) are included
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard !content.displays.isEmpty else {
            fputs("ERROR:no_display\n", stderr)
            exit(1)
        }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = false
        config.sampleRate = 48000
        config.channelCount = 2
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        // includingApplications with ALL apps captures audio from background helpers
        // (e.g. com.google.Chrome.helper) that have no visible window on the display.
        // The previous excludingApplications:[] filter missed those processes.
        let filter = SCContentFilter(
            display: content.displays[0],
            including: content.applications,
            exceptingWindows: []
        )
        stream = SCStream(filter: filter, configuration: config, delegate: self)
        guard stream != nil else {
            fputs("ERROR:stream_nil\n", stderr)
            exit(1)
        }

        try stream!.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global())
        try stream!.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global())
        try await stream!.startCapture()
        fputs("READY\n", stderr)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }

        guard let fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc) else { return }

        var mutableASBD = asbd.pointee
        guard let srcFormat = AVAudioFormat(streamDescription: &mutableASBD) else { return }

        if converter == nil || lastInputFormat != srcFormat {
            lastInputFormat = srcFormat
            converter = AVAudioConverter(from: srcFormat, to: TARGET_FORMAT)
        }
        guard let conv = converter else { return }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else { return }
        srcBuffer.frameLength = frameCount
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frameCount), into: srcBuffer.mutableAudioBufferList
        ) == noErr else { return }

        let outFrames = AVAudioFrameCount(ceil(Double(frameCount) * TARGET_RATE / srcFormat.sampleRate))
        guard let dstBuffer = AVAudioPCMBuffer(pcmFormat: TARGET_FORMAT, frameCapacity: outFrames) else { return }

        var inputGiven = false
        var convError: NSError?
        conv.convert(to: dstBuffer, error: &convError) { _, status in
            if inputGiven { status.pointee = .noDataNow; return nil }
            inputGiven = true
            status.pointee = .haveData
            return srcBuffer
        }

        guard convError == nil, dstBuffer.frameLength > 0,
              let int16Ptr = dstBuffer.int16ChannelData else { return }

        let byteCount = Int(dstBuffer.frameLength) * 2
        let data = Data(bytes: int16Ptr[0], count: byteCount)
        outputHandle.write(data)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fputs("ERROR:\(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

signal(SIGTERM) { _ in exit(0) }
signal(SIGINT)  { _ in exit(0) }

let streamer = AudioStreamer()
Task {
    do {
        try await streamer.start()
    } catch {
        fputs("ERROR:\(error)\n", stderr)
        exit(1)
    }
}
RunLoop.main.run()
