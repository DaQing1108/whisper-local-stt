import Foundation
import ScreenCaptureKit
import AVFoundation

class AudioCapturePOC: NSObject, SCStreamOutput, SCStreamDelegate {
    var stream: SCStream?
    var audioFile: AVAudioFile?
    let outputURL: URL
    var capturedFrames = 0
    let maxFrames = 250

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    func start() async throws {
        print("[PoC] 取得 shareable content…")
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        print("[PoC] displays=\(content.displays.count), apps=\(content.applications.count)")
        guard !content.displays.isEmpty else {
            print("❌ 無可用 display")
            exit(1)
        }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        // 最小 video frame 避免 stream 被拒
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)  // 1fps

        let filter = SCContentFilter(display: content.displays[0], excludingApplications: [], exceptingWindows: [])
        print("[PoC] 建立 SCStream…")
        stream = SCStream(filter: filter, configuration: config, delegate: self)

        guard stream != nil else {
            print("❌ SCStream init 回傳 nil")
            exit(1)
        }
        print("[PoC] SCStream 建立成功，加入 output…")

        try stream!.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global())
        try stream!.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global())

        print("[PoC] 啟動 stream…")
        try await stream!.startCapture()
        print("✅ 開始擷取系統音訊！")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard capturedFrames < maxFrames else { return }

        if audioFile == nil {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000.0,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
            ]
            audioFile = try? AVAudioFile(forWriting: outputURL, settings: settings)
            print("[PoC] 開始寫入音訊…")
        }

        if let pcmBuffer = Self.toPCMBuffer(sampleBuffer) {
            try? audioFile?.write(from: pcmBuffer)
            capturedFrames += 1
            if capturedFrames % 50 == 0 { print("[PoC] frames=\(capturedFrames)") }
        }

        if capturedFrames >= maxFrames {
            Task {
                try? await stream.stopCapture()
                self.audioFile = nil  // flush & close WAV header
                print("✅ 完成！\(self.outputURL.path)")
                exit(0)
            }
        }
    }

    static func toPCMBuffer(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return nil }
        var mutableASBD = asbd.pointee
        guard let format = AVAudioFormat(streamDescription: &mutableASBD) else { return nil }
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frameCount), into: buffer.mutableAudioBufferList) == noErr else { return nil }
        return buffer
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("❌ Stream 錯誤：\(error)")
        exit(1)
    }
}

let outputURL = URL(fileURLWithPath: "/tmp/poc_system_audio.wav")
let poc = AudioCapturePOC(outputURL: outputURL)

Task {
    do {
        try await poc.start()
    } catch {
        print("❌ 失敗：\(error)")
        exit(1)
    }
}

RunLoop.main.run(until: Date(timeIntervalSinceNow: 15))
print("⏰ 逾時")
exit(0)
