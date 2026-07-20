@preconcurrency import ScreenCaptureKit
@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import Foundation

private final class SystemAudioStreamOutput: NSObject, SCStreamOutput {
    private let gate: SystemAudioCallbackGate
    private let lock = NSLock()
    private var generation: Int?
    private var onPCM: (@Sendable (Data) -> Void)?
    private var onError: (@MainActor @Sendable (Error) -> Void)?

    init(gate: SystemAudioCallbackGate) {
        self.gate = gate
    }

    func activate(_ generation: Int) {
        lock.withLock { self.generation = generation }
    }

    func setHandlers(onPCM: @escaping @Sendable (Data) -> Void, onError: @escaping @MainActor @Sendable (Error) -> Void) {
        lock.withLock { self.onPCM = onPCM; self.onError = onError }
    }

    func deactivate() {
        let generation = lock.withLock { self.generation }
        guard let generation else { return }
        gate.close(generation: generation)
        lock.withLock { self.generation = nil }
    }

    private func report(_ error: Error, generation: Int, to handler: @escaping @MainActor @Sendable (Error) -> Void) {
        Task { @MainActor [gate] in
            guard gate.isAccepting(generation: generation) else { return }
            handler(error)
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        let handlers = lock.withLock { (self.generation, self.onPCM, self.onError) }
        guard let generation = handlers.0,
              let onPCM = handlers.1,
              let onError = handlers.2,
              gate.begin(generation: generation) else { return }
        defer { gate.end(generation: generation) }
        guard type == .audio else { return }
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description) else {
            report(SystemAudioCaptureError.conversionFailed("invalid sample format"), generation: generation, to: onError)
            return
        }
        var streamDescription = asbd.pointee
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            report(SystemAudioCaptureError.conversionFailed("unsupported audio format"), generation: generation, to: onError)
            return
        }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            report(SystemAudioCaptureError.conversionFailed("buffer allocation failed"), generation: generation, to: onError)
            return
        }
        buffer.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList) == noErr else {
            report(SystemAudioCaptureError.conversionFailed("PCM copy failed"), generation: generation, to: onError)
            return
        }
        do { if let pcm = try SystemAudioPCMConverter.convert(buffer) { onPCM(pcm) } }
        catch { report(SystemAudioCaptureError.conversionFailed(error.localizedDescription), generation: generation, to: onError) }
    }
}

@MainActor
final class ScreenCaptureKitAudioBackend: NSObject, SystemAudioCaptureBackend, SCStreamDelegate {
    private let gate = SystemAudioCallbackGate()
    private let output: SystemAudioStreamOutput
    private let outputQueue = DispatchQueue(label: "com.via.whisper-swiftui.system-audio-output")
    private var stream: SCStream?
    private var isStarting = false
    private var isStopping = false
    private var stopRequestedDuringStart = false
    private var onError: @MainActor @Sendable (Error) -> Void
    private var onPCM: @Sendable (Data) -> Void

    init(onPCM: @escaping @Sendable (Data) -> Void = { _ in }, onError: @escaping @MainActor @Sendable (Error) -> Void = { _ in }) {
        output = SystemAudioStreamOutput(gate: gate)
        self.onPCM = onPCM
        self.onError = onError
        super.init()
    }

    func setErrorHandler(_ handler: @escaping @MainActor @Sendable (Error) -> Void) {
        onError = handler
    }

    func setPCMHandler(_ handler: @escaping @Sendable (Data) -> Void) {
        onPCM = handler
    }

    func start() async throws {
        guard stream == nil, !isStarting else { return }
        isStarting = true
        stopRequestedDuringStart = false
        let generation = gate.open()
        output.setHandlers(onPCM: onPCM, onError: onError)
        output.activate(generation)
        defer { isStarting = false }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
        } catch {
            output.deactivate()
            throw error
        }
        guard let display = content.displays.first else {
            output.deactivate()
            throw ScreenCaptureKitAudioBackendError.noDisplayAvailable
        }

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = false
        configuration.sampleRate = 48_000
        configuration.channelCount = 2

        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )
        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try newStream.addStreamOutput(output, type: .audio, sampleHandlerQueue: outputQueue)
            try await newStream.startCapture()
            if stopRequestedDuringStart {
                stopRequestedDuringStart = false
                output.deactivate()
                try await newStream.stopCapture()
                return
            }
            stream = newStream
        } catch {
            output.deactivate()
            stopRequestedDuringStart = false
            try? await newStream.stopCapture()
            throw error
        }
    }

    func stop() async throws {
        if isStarting {
            stopRequestedDuringStart = true
            return
        }
        guard !isStopping, let stream else { return }
        isStopping = true
        defer { isStopping = false }
        output.deactivate()
        try await stream.stopCapture()
        self.stream = nil
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.stream === stream else { return }
            self.onError(SystemAudioCaptureError.streamStopped(error.localizedDescription))
        }
    }
}

enum ScreenCaptureKitAudioBackendError: Error, Equatable {
    case noDisplayAvailable
}
