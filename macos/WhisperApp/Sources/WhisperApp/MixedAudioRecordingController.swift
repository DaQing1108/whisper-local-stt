import Foundation
import Observation

enum MixedAudioRecordingState: Equatable, Sendable {
    case idle
    case starting
    case recording
    case stopping
    case failed(String)
}

enum MixedAudioRecordingError: Error {
    case recordingAlreadyActive
    case microphonePermissionDenied
    case screenRecordingPermissionDenied
    case captureFailed(String)
    case workerNotReady
}

private final class MixedAudioAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var microphone = Data()
    private var system = Data()

    func appendMicrophone(_ data: Data) { lock.withLock { microphone.append(data) } }
    func appendSystem(_ data: Data) { lock.withLock { system.append(data) } }

    func drain() -> Data {
        lock.withLock {
            defer {
                microphone.removeAll(keepingCapacity: true)
                system.removeAll(keepingCapacity: true)
            }
            if microphone.isEmpty { return system }
            if system.isEmpty { return microphone }
            return PCM16Mixer.mix(microphone, system)
        }
    }
}

private final class MixedAudioErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?
    func record(_ newError: Error) { lock.withLock { if error == nil { error = newError } } }
    var value: Error? { lock.withLock { error } }
}

@MainActor
@Observable
final class MixedAudioRecordingController {
    private(set) var state: MixedAudioRecordingState = .idle
    private(set) var lastFinalizedURL: URL?

    private let microphonePermission: any MicrophonePermissionProviding
    private let screenPermission: SystemAudioPermissionController
    private let microphoneBackend: any AudioCaptureBackend
    private let systemBackend: any SystemAudioCaptureBackend
    private let scheduler: any ChunkRotationScheduling
    private let transcriber: (any AudioTranscribing)?
    private let flushInterval: TimeInterval
    private var accumulator: MixedAudioAccumulator?
    private var session: SystemAudioWAVSession?
    private var microphoneActive = false
    private var systemActive = false
    private var errorBox: MixedAudioErrorBox?
    private var isStarting = false
    private var stopRequestedDuringStart = false
    private var stopTask: Task<URL, Error>?
    private var stopOperationID: UUID?

    var hasActiveOperation: Bool {
        isStarting || stopTask != nil || session != nil || microphoneActive || systemActive
    }
    var canStart: Bool { !hasActiveOperation }
    var canStop: Bool { session != nil && (microphoneActive || systemActive) }

    init(
        microphonePermission: any MicrophonePermissionProviding,
        screenPermission: SystemAudioPermissionController,
        microphoneBackend: any AudioCaptureBackend,
        systemBackend: any SystemAudioCaptureBackend,
        scheduler: any ChunkRotationScheduling,
        transcriber: (any AudioTranscribing)?,
        flushInterval: TimeInterval = 15
    ) {
        self.microphonePermission = microphonePermission
        self.screenPermission = screenPermission
        self.microphoneBackend = microphoneBackend
        self.systemBackend = systemBackend
        self.scheduler = scheduler
        self.transcriber = transcriber
        self.flushInterval = flushInterval
        systemBackend.setErrorHandler { [weak self] error in self?.errorBox?.record(error) }
    }

    func start(outputURL: URL) async throws {
        guard !isStarting, stopTask == nil, canStart else {
            throw MixedAudioRecordingError.recordingAlreadyActive
        }
        isStarting = true
        stopRequestedDuringStart = false
        state = .starting
        defer { isStarting = false }
        let microphoneGranted: Bool
        switch microphonePermission.status() {
        case .granted: microphoneGranted = true
        case .notDetermined: microphoneGranted = await microphonePermission.requestAccess()
        case .denied, .restricted: microphoneGranted = false
        }
        guard microphoneGranted else {
            state = .failed("Microphone access is required for mixed audio")
            throw MixedAudioRecordingError.microphonePermissionDenied
        }
        screenPermission.refresh()
        guard screenPermission.status == .granted else {
            state = .failed("Screen Recording access is required for mixed audio")
            throw MixedAudioRecordingError.screenRecordingPermissionDenied
        }

        lastFinalizedURL = nil
        let errorBox = MixedAudioErrorBox()
        self.errorBox = errorBox
        let accumulator = MixedAudioAccumulator()
        let session = try SystemAudioWAVSession(url: outputURL)
        self.accumulator = accumulator
        self.session = session
        systemBackend.setPCMHandler { [weak accumulator] in accumulator?.appendSystem($0) }

        do {
            try await systemBackend.start()
            systemActive = true
            try microphoneBackend.start(
                onPCM: { [weak accumulator] in accumulator?.appendMicrophone($0) },
                onError: { [weak errorBox] error in errorBox?.record(error) }
            )
            microphoneActive = true
            scheduler.schedule(every: flushInterval) { [weak self] in self?.flush() }
            state = stopRequestedDuringStart ? .stopping : .recording
        } catch {
            if systemActive {
                do {
                    try await systemBackend.stop()
                    systemActive = false
                } catch {
                    state = .failed(error.localizedDescription)
                    throw error
                }
            }
            _ = try? session.finalize()
            try? FileManager.default.removeItem(at: outputURL)
            self.session = nil
            self.accumulator = nil
            self.errorBox = nil
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    @discardableResult
    func stop() async throws -> URL {
        if isStarting {
            stopRequestedDuringStart = true
            state = .stopping
            while isStarting { await Task.yield() }
        }
        if let stopTask { return try await stopTask.value }
        let operationID = UUID()
        let task = Task { @MainActor [weak self] () throws -> URL in
            guard let self else { throw MixedAudioRecordingError.captureFailed("Controller released") }
            return try await self.performStop()
        }
        stopTask = task
        stopOperationID = operationID
        do {
            let url = try await task.value
            clearStopOperation(if: operationID)
            return url
        } catch {
            clearStopOperation(if: operationID)
            throw error
        }
    }

    private func performStop() async throws -> URL {
        guard let session else { throw MixedAudioRecordingError.captureFailed("No mixed-audio session") }
        state = .stopping
        scheduler.cancel()
        var stopError: Error?
        if microphoneActive {
            do { try microphoneBackend.stop(); microphoneActive = false } catch { stopError = error }
        }
        if systemActive {
            do { try await systemBackend.stop(); systemActive = false } catch { if stopError == nil { stopError = error } }
        }
        flush()
        if let error = stopError {
            state = .failed(error.localizedDescription)
            throw MixedAudioRecordingError.captureFailed(error.localizedDescription)
        }
        if let error = errorBox?.value ?? session.writeError {
            _ = try? session.finalize()
            try? FileManager.default.removeItem(at: session.url)
            self.session = nil
            accumulator = nil
            errorBox = nil
            state = .failed(error.localizedDescription)
            throw MixedAudioRecordingError.captureFailed(error.localizedDescription)
        }
        let url = try session.finalize()
        self.session = nil
        accumulator = nil
        errorBox = nil
        lastFinalizedURL = url
        state = .idle
        return url
    }

    @discardableResult
    func stopAndTranscribe(
        modelName: String, language: String? = nil, domain: String = "general", extraTerms: String = ""
    ) async throws -> URL {
        let url = try await stop()
        guard let transcriber, transcriber.state == .ready else {
            throw MixedAudioRecordingError.workerNotReady
        }
        _ = try transcriber.transcribe(
            audioURL: url, modelName: modelName, language: language,
            domain: domain, extraTerms: extraTerms
        )
        return url
    }

    private func flush() {
        guard let pcm = accumulator?.drain(), !pcm.isEmpty else { return }
        do { try session?.append(pcm) } catch {
            errorBox?.record(error)
            state = .failed(error.localizedDescription)
        }
    }

    private func clearStopOperation(if operationID: UUID) {
        guard stopOperationID == operationID else { return }
        stopTask = nil
        stopOperationID = nil
    }
}
