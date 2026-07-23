import Foundation
import Observation

enum SystemAudioRecordingError: Error {
    case recordingAlreadyActive
    case captureDidNotStart
    case captureDidNotStop
    case writeFailed(String)
    case captureFailed(String)
    case workerNotReady
}

@MainActor
@Observable
final class SystemAudioRecordingController {
    private let lifecycle: SystemAudioCaptureLifecycleController
    private let backend: any SystemAudioCaptureBackend
    private let scheduler: any ChunkRotationScheduling
    private let rotationInterval: TimeInterval
    private let outputURLFactory: @Sendable () throws -> URL
    private var session: RotatingCaptureSession?
    private var sessionWriter: SystemAudioWAVSession?
    private var isHandlingCaptureFailure = false
    private var completedChunkURLs: Set<URL> = []
    private(set) var lastFinalizedURL: URL?
    private(set) var finalizedChunkURLs: [URL] = []
    private(set) var transcriptText = ""
    private(set) var transcriptSegments: [TranscriptionSegment] = []
    private(set) var transcriptDurationSeconds: Double = 0
    private(set) var sessionFinalizedURL: URL?
    let submissionQueue: OrderedChunkSubmissionQueue

    var state: SystemAudioCaptureState { lifecycle.state }
    var canStart: Bool {
        session == nil && !lifecycle.hasActiveCapture &&
            submissionQueue.activeURL == nil && submissionQueue.pendingURLs.isEmpty
    }
    var canStop: Bool { session != nil && lifecycle.hasActiveCapture }
    var isDraining: Bool {
        session == nil && (submissionQueue.activeURL != nil || !submissionQueue.pendingURLs.isEmpty)
    }
    var hasActiveOperation: Bool { canStop || isDraining }
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
        lifecycle: SystemAudioCaptureLifecycleController,
        backend: any SystemAudioCaptureBackend,
        transcriber: any LiveAudioTranscribing,
        scheduler: any ChunkRotationScheduling = TimerChunkRotationScheduler(),
        rotationInterval: TimeInterval = 15,
        outputURLFactory: @escaping @Sendable () throws -> URL = {
            try SystemAudioRecordingController.makeChunkOutputURL()
        }
    ) {
        self.lifecycle = lifecycle
        self.backend = backend
        self.scheduler = scheduler
        self.rotationInterval = rotationInterval
        self.outputURLFactory = outputURLFactory
        submissionQueue = OrderedChunkSubmissionQueue(transcriber: transcriber, modelName: "base")
        submissionQueue.queueDrainedHandler = { [weak self] in
            self?.removeCompletedChunkFiles()
        }
    }

    func start(outputURL: URL) async throws {
        let sessionURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent("system-audio-session-\(UUID()).wav")
        try await start(outputURLFactory: { outputURL }, sessionOutputURL: sessionURL)
    }

    private func start(
        outputURLFactory: @escaping @Sendable () throws -> URL,
        sessionOutputURL: URL
    ) async throws {
        guard session == nil else { throw SystemAudioRecordingError.recordingAlreadyActive }
        lastFinalizedURL = nil
        finalizedChunkURLs = []
        completedChunkURLs = []
        transcriptText = ""
        transcriptSegments = []
        transcriptDurationSeconds = 0
        sessionFinalizedURL = nil
        isHandlingCaptureFailure = false
        let session = try RotatingCaptureSession(outputURLFactory: outputURLFactory)
        let sessionWriter = try SystemAudioWAVSession(url: sessionOutputURL)
        self.session = session
        self.sessionWriter = sessionWriter
        backend.setPCMHandler { [weak self, weak session, weak sessionWriter] pcm in
            do {
                try session?.append(pcm)
                try sessionWriter?.append(pcm)
            }
            catch {
                Task { @MainActor [weak self] in await self?.handleCaptureFailure(error) }
            }
        }
        await lifecycle.start()
        guard lifecycle.state == .capturing else {
            _ = try? session.finish()
            _ = try? sessionWriter.finalize()
            try? FileManager.default.removeItem(at: sessionOutputURL)
            self.session = nil
            self.sessionWriter = nil
            throw SystemAudioRecordingError.captureDidNotStart
        }
        scheduler.schedule(every: rotationInterval) { [weak self] in self?.rotateChunk() }
    }

    func start() async throws {
        try await start(
            outputURLFactory: outputURLFactory,
            sessionOutputURL: try Self.makeSessionOutputURL()
        )
    }

    func start(
        modelName: String, language: String? = nil, domain: String = "general", extraTerms: String = ""
    ) async throws {
        self.modelName = modelName
        self.language = language
        self.domain = domain
        self.extraTerms = extraTerms
        try await start()
    }

    @discardableResult
    func stop() async throws -> URL? {
        scheduler.cancel()
        let terminalError = lifecycle.terminalError
        await lifecycle.stop()
        defer {
            session = nil
            sessionWriter = nil
        }
        var chunkError: Error?
        let url: URL?
        do { url = try session?.finish() }
        catch { url = nil; chunkError = error }
        if let url { acceptFinalizedChunk(url) }
        var sessionError: Error?
        if let sessionWriter {
            do {
                let finalizedURL = try sessionWriter.finalize()
                if sessionWriter.writeError == nil {
                    sessionFinalizedURL = finalizedURL
                    if submissionQueue.activeURL == nil && submissionQueue.pendingURLs.isEmpty {
                        removeCompletedChunkFiles()
                    }
                }
            } catch {
                sessionError = error
                sessionFinalizedURL = nil
            }
        }
        if let error = chunkError ?? sessionError {
            throw SystemAudioRecordingError.writeFailed(error.localizedDescription)
        }
        guard lifecycle.state == .idle else { throw SystemAudioRecordingError.captureDidNotStop }
        if let terminalError {
            lifecycle.handleRuntimeError(terminalError)
            throw SystemAudioRecordingError.captureFailed(terminalError.localizedDescription)
        }
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
        let finalChunkURL = try await stop()
        guard let url = sessionFinalizedURL ?? finalChunkURL else {
            throw SystemAudioRecordingError.captureDidNotStop
        }
        return url
    }

    private func rotateChunk() {
        guard lifecycle.state == .capturing, let session else { return }
        do {
            if let url = try session.rotate() { acceptFinalizedChunk(url) }
        } catch {
            scheduler.cancel()
            Task { @MainActor [weak self] in await self?.handleCaptureFailure(error) }
        }
    }

    private func handleCaptureFailure(_ error: Error) async {
        guard !isHandlingCaptureFailure, session != nil else { return }
        isHandlingCaptureFailure = true
        scheduler.cancel()
        lifecycle.handleRuntimeError(error)
        _ = try? await stop()
        isHandlingCaptureFailure = false
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
        let chunkDuration = max(maximumSegmentEnd, durationSeconds ?? rotationInterval)
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

    nonisolated private static func makeChunkOutputURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base
            .appendingPathComponent("WhisperSwiftUI", isDirectory: true)
            .appendingPathComponent("SystemAudioChunks", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("system-audio-chunk-\(UUID()).wav")
    }

    nonisolated private static func makeSessionOutputURL() throws -> URL {
        let chunkURL = try makeChunkOutputURL()
        return chunkURL.deletingLastPathComponent()
            .appendingPathComponent("system-audio-session-\(UUID()).wav")
    }
}
