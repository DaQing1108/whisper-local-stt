@preconcurrency import AVFoundation
import Foundation
import Observation

enum MicrophonePermission: Equatable, Sendable {
    case notDetermined
    case granted
    case denied
    case restricted
}

protocol MicrophonePermissionProviding: Sendable {
    func status() -> MicrophonePermission
    func requestAccess() async -> Bool
}

struct SystemMicrophonePermissionProvider: MicrophonePermissionProviding {
    func status() -> MicrophonePermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: .notDetermined
        case .authorized: .granted
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .restricted
        }
    }

    func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}

protocol AudioCaptureBackend: Sendable {
    func start(
        onPCM: @escaping @Sendable (Data) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) throws
    /// Stops capture and returns only after all callbacks accepted before stop have completed.
    /// Must not be called synchronously from an `onPCM` or `onError` callback.
    func stop() throws
}

enum AudioCaptureError: Error, Equatable {
    case permissionDenied
    case permissionRestricted
    case invalidInputFormat
    case converterUnavailable
    case conversionFailed
    case noOutputData
}

private final class ConverterInput: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func take() -> AVAudioPCMBuffer? {
        lock.lock()
        defer { lock.unlock() }
        defer { buffer = nil }
        return buffer
    }
}

private final class CaptureSession: @unchecked Sendable {
    let id = UUID()
    let url: URL
    private let lock = NSLock()
    private let writer: PCM16WAVWriter
    private var finalized = false

    init(url: URL) throws {
        self.url = url
        writer = try PCM16WAVWriter(url: url)
    }

    func append(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !finalized else { return }
        try writer.append(data)
    }

    @discardableResult
    func finalize() throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        guard !finalized else { return url }
        let finalizedURL = try writer.finalize()
        finalized = true
        return finalizedURL
    }
}

final class AVAudioEngineCaptureBackend: AudioCaptureBackend, @unchecked Sendable {
    private var engine: AVAudioEngine
    private let lock = NSLock()
    private let callbackLock = NSLock()
    private let callbacksDrained = DispatchGroup()
    private let captureQueue = DispatchQueue(label: "com.via.whisper-swiftui.microphone-capture")
    private let captureQueueKey = DispatchSpecificKey<UInt8>()
    private var isCapturing = false
    private var acceptsCallbacks = false
    private var retiredEngines: [AVAudioEngine] = []

    init(engine: AVAudioEngine = AVAudioEngine()) {
        self.engine = engine
        captureQueue.setSpecific(key: captureQueueKey, value: 1)
    }

    static func convert(
        _ buffer: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        to outputFormat: AVAudioFormat
    ) throws -> Data? {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw AudioCaptureError.noOutputData
        }
        let input = ConverterInput(buffer)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard let buffer = input.take() else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputStatus.pointee = .haveData
            return buffer
        }
        if let conversionError { throw conversionError }
        guard status != .error else { throw AudioCaptureError.conversionFailed }
        guard output.frameLength > 0, let bytes = output.audioBufferList.pointee.mBuffers.mData else {
            return nil
        }
        let byteCount = Int(output.frameLength) * Int(outputFormat.streamDescription.pointee.mBytesPerFrame)
        return Data(bytes: bytes, count: byteCount)
    }

    func start(
        onPCM: @escaping @Sendable (Data) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isCapturing else { return }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioCaptureError.invalidInputFormat
        }
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(PCM16WAVWriter.sampleRate),
            channels: AVAudioChannelCount(PCM16WAVWriter.channelCount),
            interleaved: true
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioCaptureError.converterUnavailable
        }

        callbackLock.lock()
        acceptsCallbacks = true
        callbackLock.unlock()
        input.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { buffer, _ in
            self.callbackLock.lock()
            guard self.acceptsCallbacks else {
                self.callbackLock.unlock()
                return
            }
            self.callbacksDrained.enter()
            self.callbackLock.unlock()
            self.captureQueue.sync {
                defer { self.callbacksDrained.leave() }
                do {
                    if let data = try Self.convert(buffer, with: converter, to: outputFormat) {
                        onPCM(data)
                    }
                } catch {
                    onError(error)
                }
            }
        }

        do {
            engine.prepare()
            try engine.start()
            isCapturing = true
        } catch {
            teardownEngine()
            throw error
        }
    }

    func stop() throws {
        precondition(
            DispatchQueue.getSpecific(key: captureQueueKey) == nil,
            "AudioCaptureBackend.stop() must not be called synchronously from a capture callback"
        )
        lock.lock()
        defer { lock.unlock() }
        guard isCapturing else { return }
        teardownEngine()
    }

    private func teardownEngine() {
        callbackLock.lock()
        acceptsCallbacks = false
        callbackLock.unlock()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        isCapturing = false
        callbacksDrained.wait()
        let retiredEngine = engine
        engine = AVAudioEngine()
        retiredEngines.append(retiredEngine)
        captureQueue.async { [weak self, retiredEngine] in
            self?.releaseRetiredEngine(retiredEngine)
        }
    }

    private func releaseRetiredEngine(_ engine: AVAudioEngine) {
        lock.lock()
        retiredEngines.removeAll { $0 === engine }
        lock.unlock()
    }
}

@MainActor
@Observable
final class MicrophoneCaptureService {
    private(set) var machine = RecordingStateMachine()
    private(set) var lastFinalizedURL: URL?
    private(set) var audioLevel: Double = 0
    private let permissionProvider: any MicrophonePermissionProviding
    private let backend: any AudioCaptureBackend
    private var session: CaptureSession?

    var state: RecordingState { machine.state }

    init(
        permissionProvider: any MicrophonePermissionProviding = SystemMicrophonePermissionProvider(),
        backend: any AudioCaptureBackend = AVAudioEngineCaptureBackend()
    ) {
        self.permissionProvider = permissionProvider
        self.backend = backend
    }

    @discardableResult
    func resolvePermission() async -> Bool {
        do {
            try machine.requestPermission()
            switch permissionProvider.status() {
            case .granted:
                try machine.permissionResolved(granted: true)
                return true
            case .notDetermined:
                let granted = await permissionProvider.requestAccess()
                try machine.permissionResolved(granted: granted)
                return granted
            case .denied:
                machine.fail("Microphone permission denied")
                return false
            case .restricted:
                machine.fail("Microphone permission restricted")
                return false
            }
        } catch {
            machine.fail(error.localizedDescription)
            return false
        }
    }

    func start(outputURL: URL, at date: Date = Date()) throws {
        guard machine.state == .ready else { throw RecordingStateError.invalidTransition }
        lastFinalizedURL = nil
        let session = try CaptureSession(url: outputURL)
        self.session = session
        do {
            try backend.start(
                onPCM: { [weak self, session] data in
                    do { try session.append(data) }
                    catch {
                        Task { @MainActor in self?.captureFailed(error, sessionID: session.id) }
                    }
                    let level = Self.normalizedLevel(forPCM16: data)
                    Task { @MainActor in self?.audioLevel = level }
                },
                onError: { [weak self, session] error in
                    Task { @MainActor in self?.captureFailed(error, sessionID: session.id) }
                }
            )
            try machine.start(at: date)
        } catch {
            _ = try? session.finalize()
            self.session = nil
            machine.fail(error.localizedDescription)
            throw error
        }
    }

    @discardableResult
    func stop() throws -> URL {
        try machine.stop()
        guard let session else {
            machine.fail(AudioCaptureError.noOutputData.localizedDescription)
            throw AudioCaptureError.noOutputData
        }
        var stopError: Error?
        do {
            try backend.stop()
        } catch {
            stopError = error
        }
        do {
            let url = try session.finalize()
            lastFinalizedURL = url
            self.session = nil
            if let stopError {
                machine.fail(stopError.localizedDescription)
                throw stopError
            }
            try machine.finalized(at: url)
            audioLevel = 0
            return url
        } catch {
            self.session = nil
            machine.fail(error.localizedDescription)
            throw error
        }
    }

    func reset() {
        if let session {
            try? backend.stop()
            _ = try? session.finalize()
        }
        session = nil
        machine.reset()
        audioLevel = 0
    }

    private func captureFailed(_ error: Error, sessionID: UUID) {
        guard session?.id == sessionID, machine.state.canStop else { return }
        try? backend.stop()
        lastFinalizedURL = try? session?.finalize()
        session = nil
        machine.fail(error.localizedDescription)
        audioLevel = 0
    }

    nonisolated static func normalizedLevel(forPCM16 data: Data) -> Double {
        guard data.count >= MemoryLayout<Int16>.size else { return 0 }
        let meanSquare = data.withUnsafeBytes { raw -> Double in
            let samples = raw.bindMemory(to: Int16.self)
            let sum = samples.reduce(0.0) { partial, sample in
                let normalized = Double(Int16(littleEndian: sample)) / Double(Int16.max)
                return partial + normalized * normalized
            }
            return sum / Double(samples.count)
        }
        return min(max(sqrt(meanSquare), 0), 1)
    }
}
