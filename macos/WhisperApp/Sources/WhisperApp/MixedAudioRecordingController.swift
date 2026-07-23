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
    private(set) var finalizedChunkURLs: [URL] = []
    private(set) var transcriptText = ""
    private(set) var transcriptSegments: [TranscriptionSegment] = []
    private(set) var transcriptDurationSeconds: Double = 0
    private(set) var sessionFinalizedURL: URL?
    let submissionQueue: OrderedChunkSubmissionQueue

    private let microphonePermission: any MicrophonePermissionProviding
    private let screenPermission: SystemAudioPermissionController
    private let microphoneBackend: any AudioCaptureBackend
    private let systemBackend: any SystemAudioCaptureBackend
    private let scheduler: any ChunkRotationScheduling
    private let flushInterval: TimeInterval
    private let chunkOutputURLFactory: @Sendable () throws -> URL
    private var accumulator: MixedAudioAccumulator?
    private var chunkSession: RotatingCaptureSession?
    private var fullSession: SystemAudioWAVSession?
    private var completedChunkURLs: Set<URL> = []
    private var microphoneActive = false
    private var systemActive = false
    private var errorBox: MixedAudioErrorBox?
    private var isStarting = false
    private var stopRequestedDuringStart = false
    private var stopTask: Task<URL, Error>?
    private var stopOperationID: UUID?
    private var didFinalFlush = false
    private var isHandlingCaptureFailure = false

    var hasActiveOperation: Bool {
        isStarting || stopTask != nil || fullSession != nil || microphoneActive || systemActive
    }
    var isDraining: Bool {
        fullSession == nil && (submissionQueue.activeURL != nil || !submissionQueue.pendingURLs.isEmpty)
    }
    var canStart: Bool { !hasActiveOperation && !isDraining }
    var canStop: Bool { fullSession != nil && (microphoneActive || systemActive) }

    var modelName: String {
        get { submissionQueue.modelName }
        set { submissionQueue.modelName = newValue }
    }
    var language: String? {
        get { submissionQueue.language }
        set { submissionQueue.language = newValue }
    }
    var domain: String {
        get { submissionQueue.domain }
        set { submissionQueue.domain = newValue }
    }
    var extraTerms: String {
        get { submissionQueue.extraTerms }
        set { submissionQueue.extraTerms = newValue }
    }

    init(
        microphonePermission: any MicrophonePermissionProviding,
        screenPermission: SystemAudioPermissionController,
        microphoneBackend: any AudioCaptureBackend,
        systemBackend: any SystemAudioCaptureBackend,
        scheduler: any ChunkRotationScheduling,
        transcriber: any LiveAudioTranscribing,
        flushInterval: TimeInterval = 15,
        chunkOutputURLFactory: @escaping @Sendable () throws -> URL = {
            try MixedAudioRecordingController.makeChunkOutputURL()
        }
    ) {
        self.microphonePermission = microphonePermission
        self.screenPermission = screenPermission
        self.microphoneBackend = microphoneBackend
        self.systemBackend = systemBackend
        self.scheduler = scheduler
        self.flushInterval = flushInterval
        self.chunkOutputURLFactory = chunkOutputURLFactory
        submissionQueue = OrderedChunkSubmissionQueue(transcriber: transcriber, modelName: "base")
        submissionQueue.queueDrainedHandler = { [weak self] in
            self?.removeCompletedChunkFiles()
        }
        systemBackend.setErrorHandler { [weak self] error in self?.errorBox?.record(error) }
    }

    func start(outputURL: URL, includeMicrophone: Bool = true) async throws {
        guard !isStarting, stopTask == nil, canStart else {
            throw MixedAudioRecordingError.recordingAlreadyActive
        }
        isStarting = true
        stopRequestedDuringStart = false
        state = .starting
        defer { isStarting = false }
        if includeMicrophone {
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
        }
        screenPermission.refresh()
        guard screenPermission.status == .granted else {
            state = .failed("Screen Recording access is required for mixed audio")
            throw MixedAudioRecordingError.screenRecordingPermissionDenied
        }

        lastFinalizedURL = nil
        finalizedChunkURLs = []
        completedChunkURLs = []
        transcriptText = ""
        transcriptSegments = []
        transcriptDurationSeconds = 0
        sessionFinalizedURL = nil
        didFinalFlush = false
        isHandlingCaptureFailure = false
        let errorBox = MixedAudioErrorBox()
        self.errorBox = errorBox
        let accumulator = MixedAudioAccumulator()
        let fullSession = try SystemAudioWAVSession(url: outputURL)
        let chunkSession = try RotatingCaptureSession(outputURLFactory: chunkOutputURLFactory)
        self.accumulator = accumulator
        self.fullSession = fullSession
        self.chunkSession = chunkSession
        systemBackend.setPCMHandler { [weak accumulator] in accumulator?.appendSystem($0) }

        do {
            try await systemBackend.start()
            systemActive = true
            if includeMicrophone {
                try microphoneBackend.start(
                    onPCM: { [weak accumulator] in accumulator?.appendMicrophone($0) },
                    onError: { [weak errorBox] error in errorBox?.record(error) }
                )
                microphoneActive = true
            }
            scheduler.schedule(every: flushInterval) { [weak self] in self?.rotateChunk() }
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
            _ = try? fullSession.finalize()
            _ = try? chunkSession.finish()
            try? FileManager.default.removeItem(at: outputURL)
            self.fullSession = nil
            self.chunkSession = nil
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
        guard let fullSession else { throw MixedAudioRecordingError.captureFailed("No mixed-audio session") }
        state = .stopping
        scheduler.cancel()
        var stopError: Error?
        if microphoneActive {
            do { try microphoneBackend.stop(); microphoneActive = false } catch { stopError = error }
        }
        if systemActive {
            do { try await systemBackend.stop(); systemActive = false } catch { if stopError == nil { stopError = error } }
        }
        if !didFinalFlush {
            finalFlush()
            didFinalFlush = true
        }
        if let error = stopError {
            state = .failed(error.localizedDescription)
            throw MixedAudioRecordingError.captureFailed(error.localizedDescription)
        }
        if let error = errorBox?.value ?? fullSession.writeError {
            _ = try? fullSession.finalize()
            _ = try? chunkSession?.finish()
            try? FileManager.default.removeItem(at: fullSession.url)
            self.fullSession = nil
            self.chunkSession = nil
            accumulator = nil
            errorBox = nil
            state = .failed(error.localizedDescription)
            throw MixedAudioRecordingError.captureFailed(error.localizedDescription)
        }
        let url = try fullSession.finalize()
        if fullSession.writeError == nil {
            sessionFinalizedURL = url
            if submissionQueue.activeURL == nil && submissionQueue.pendingURLs.isEmpty {
                removeCompletedChunkFiles()
            }
        }
        self.fullSession = nil
        self.chunkSession = nil
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
        submissionQueue.modelName = modelName
        submissionQueue.language = language
        submissionQueue.domain = domain
        submissionQueue.extraTerms = extraTerms
        return try await stop()
    }

    private func rotateChunk() {
        guard let accumulator, let chunkSession, let fullSession else { return }
        let pcm = accumulator.drain()
        guard !pcm.isEmpty else { return }
        do {
            try fullSession.append(pcm)
            try chunkSession.append(pcm)
            if let url = try chunkSession.rotate() { acceptFinalizedChunk(url) }
        } catch {
            scheduler.cancel()
            Task { @MainActor [weak self] in await self?.handleCaptureFailure(error) }
        }
    }

    private func handleCaptureFailure(_ error: Error) async {
        guard !isHandlingCaptureFailure, fullSession != nil else { return }
        isHandlingCaptureFailure = true
        errorBox?.record(error)
        _ = try? await stop()
        isHandlingCaptureFailure = false
    }

    private func finalFlush() {
        guard let accumulator, let chunkSession, let fullSession else { return }
        let pcm = accumulator.drain()
        do {
            if !pcm.isEmpty {
                try fullSession.append(pcm)
                try chunkSession.append(pcm)
            }
            if let url = try chunkSession.finish() { acceptFinalizedChunk(url) }
        } catch {
            errorBox?.record(error)
        }
    }

    private func acceptFinalizedChunk(_ url: URL) {
        lastFinalizedURL = url
        finalizedChunkURLs.append(url)
        guard !AudioChunkSilenceDetector.isSilent(contentsOf: url) else {
            let duration = AudioChunkSilenceDetector.durationSeconds(contentsOf: url)
            try? FileManager.default.removeItem(at: url)
            _ = acceptCompletedChunk(url, text: "", durationSeconds: duration)
            return
        }
        submissionQueue.enqueue(url)
    }

    func ownsChunk(_ url: URL) -> Bool {
        finalizedChunkURLs.contains(url)
    }

    private func removeCompletedChunkFiles() {
        guard sessionFinalizedURL != nil else { return }
        for url in submissionQueue.completedURLs where FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    @discardableResult
    func acceptCompletedChunk(
        _ url: URL,
        text: String,
        segments: [TranscriptionSegment] = [],
        durationSeconds: Double? = nil
    ) -> Bool {
        guard ownsChunk(url), completedChunkURLs.insert(url).inserted else { return false }
        let chunkText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let offset = transcriptDurationSeconds
        let maximumSegmentEnd = segments.map(\.end).max() ?? 0
        let chunkDuration = max(maximumSegmentEnd, durationSeconds ?? flushInterval)
        var offsetSegments = segments.map {
            TranscriptionSegment(start: offset + $0.start, end: offset + $0.end, text: $0.text)
        }
        if offsetSegments.isEmpty, !chunkText.isEmpty {
            offsetSegments = [TranscriptionSegment(
                start: offset, end: offset + chunkDuration, text: chunkText
            )]
        }
        transcriptSegments.append(contentsOf: offsetSegments)
        let renderedChunk = TranscriptTimecodeFormatter.render(
            segments: offsetSegments,
            fallbackText: chunkText,
            fallbackStart: offset
        )
        if !renderedChunk.isEmpty {
            transcriptText = transcriptText.isEmpty ? renderedChunk : "\(transcriptText)\n\(renderedChunk)"
        }
        transcriptDurationSeconds += max(0, chunkDuration)
        return true
    }

    private func clearStopOperation(if operationID: UUID) {
        guard stopOperationID == operationID else { return }
        stopTask = nil
        stopOperationID = nil
    }

    nonisolated private static func makeChunkOutputURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base
            .appendingPathComponent("WhisperSwiftUI", isDirectory: true)
            .appendingPathComponent("MixedAudioChunks", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("mixed-audio-chunk-\(UUID()).wav")
    }

    nonisolated static func makeSessionOutputURL() throws -> URL {
        let chunkURL = try makeChunkOutputURL()
        return chunkURL.deletingLastPathComponent()
            .appendingPathComponent("mixed-audio-session-\(UUID()).wav")
    }
}
