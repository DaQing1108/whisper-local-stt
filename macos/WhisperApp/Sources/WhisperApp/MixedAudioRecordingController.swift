import Foundation
import Observation

enum MixedAudioRecordingState: Equatable, Sendable {
    case idle
    case starting
    case recording
    case recovering
    case stopping
    case failed(String)
}

enum MixedAudioRecordingError: LocalizedError {
    case recordingAlreadyActive
    case microphonePermissionDenied
    case screenRecordingPermissionDenied
    case captureFailed(String)
    case workerNotReady

    var errorDescription: String? {
        switch self {
        case .recordingAlreadyActive:
            "A mixed audio recording is already in progress or still stopping. Try Stop again, or wait for it to finish."
        case .microphonePermissionDenied:
            "Microphone access is required for mixed audio recording."
        case .screenRecordingPermissionDenied:
            "Screen Recording access is required for mixed audio recording."
        case .captureFailed(let reason):
            "Mixed audio capture failed: \(reason)"
        case .workerNotReady:
            "Transcription worker is not ready yet."
        }
    }
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
            return PCM16Mixer.mixNormalized(microphone, system)
        }
    }
}

private final class MixedAudioErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?
    func record(_ newError: Error) { lock.withLock { if error == nil { error = newError } } }
    var value: Error? { lock.withLock { error } }
}

/// Decides where to cut mixed-audio chunks: aligned to a local energy valley near the nominal
/// interval when one exists, bounded below by `minimumSeconds` (never cut a chunk shorter than
/// this, to avoid ballooning chunk count) and above by `maximumSeconds` (a hard cap so silence-free
/// speech doesn't grow unboundedly). Pure/deterministic given the same accumulated PCM — the only
/// state is the buffered PCM itself, which the caller drains via `takeChunk()`.
final class ChunkRotationDecider: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let nominalSeconds: Double
    private let minimumSeconds: Double
    private let maximumSeconds: Double
    private let valleySearchWindowSeconds: Double
    private let sampleRate: Double

    init(
        nominalSeconds: Double = 15,
        minimumSeconds: Double = 8,
        maximumSeconds: Double = 30,
        valleySearchWindowSeconds: Double = 3,
        sampleRate: Double = Double(PCM16WAVWriter.sampleRate)
    ) {
        self.nominalSeconds = nominalSeconds
        self.minimumSeconds = minimumSeconds
        self.maximumSeconds = maximumSeconds
        self.valleySearchWindowSeconds = valleySearchWindowSeconds
        self.sampleRate = sampleRate
    }

    private func byteOffset(forSeconds seconds: Double) -> Int {
        Int(seconds * sampleRate) * MemoryLayout<Int16>.size
    }

    /// Appends newly mixed PCM and, if a rotation point has been reached, returns the chunk to
    /// finalize (leaving any remainder buffered for the next chunk). Returns `nil` when the
    /// accumulated audio hasn't reached a valid cut point yet.
    func append(_ pcm: Data) -> Data? {
        lock.withLock {
            buffer.append(pcm)
            let minimumBytes = byteOffset(forSeconds: minimumSeconds)
            let maximumBytes = byteOffset(forSeconds: maximumSeconds)

            guard buffer.count >= minimumBytes else { return nil }

            if buffer.count >= maximumBytes {
                return takeChunk(cutAt: maximumBytes)
            }

            let nominalBytes = byteOffset(forSeconds: nominalSeconds)
            let valleyWindowBytes = byteOffset(forSeconds: valleySearchWindowSeconds)
            let searchRegionStart = max(minimumBytes, nominalBytes - valleyWindowBytes)
            // Wait until the buffer covers at least the search window centered on the nominal
            // boundary — otherwise the region searched the instant buffer.count == nominalBytes
            // is only its left half, before any silence on the right side of the nominal boundary
            // has even arrived yet. Once that minimum is met, the search region keeps growing
            // with the buffer (up to the hard cap) on every subsequent append, so silence
            // anywhere before the 30s cap is still found — not just within a fixed window frozen
            // at the moment the nominal boundary was first crossed.
            guard buffer.count >= min(nominalBytes + valleyWindowBytes, maximumBytes) else { return nil }
            let searchRegionEnd = min(buffer.count, maximumBytes)

            let searchRegion = buffer[searchRegionStart..<searchRegionEnd]
            guard let valleyOffset = AudioChunkSilenceDetector.findEnergyValley(
                in: Data(searchRegion), searchWindowSeconds: valleySearchWindowSeconds, sampleRate: sampleRate
            ) else { return nil }

            let cutAt = searchRegionStart + valleyOffset
            let cutWindow = buffer[cutAt..<min(cutAt + valleyWindowBytes, buffer.count)]
            // Only cut on an actually-quiet window (below the same threshold the downstream
            // silence filter uses) — otherwise, on continuous speech with no real pause, this
            // would pick the "least loud of several loud windows" as a fake valley instead of
            // falling through to the 30s hard cap, contradicting AC-B2's silence-free fallback.
            guard AudioChunkSilenceDetector.rootMeanSquare(ofPCM16LittleEndian: Data(cutWindow))
                < AudioChunkSilenceDetector.defaultThreshold else { return nil }
            guard cutAt >= minimumBytes else { return nil }
            return takeChunk(cutAt: cutAt)
        }
    }

    /// Drains all remaining buffered PCM unconditionally, regardless of `minimumSeconds` — used
    /// for the final flush on stop, where a short trailing chunk must still be transcribed rather
    /// than silently dropped.
    func drainRemainder() -> Data {
        lock.withLock {
            defer { buffer.removeAll(keepingCapacity: true) }
            return buffer
        }
    }

    private func takeChunk(cutAt byteOffset: Int) -> Data {
        // Rebuild `buffer` from a fresh Data rather than mutating it in place with
        // prefix/removeFirst: Foundation's Data can end up with a non-zero internal start index
        // after such slicing, which has been observed to trap inside a later removeAll() call.
        let chunk = Data(buffer.prefix(byteOffset))
        buffer = Data(buffer.suffix(from: byteOffset))
        return chunk
    }
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
    private let chunkRotationDecider: ChunkRotationDecider
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
    private let eventMonitor: any AudioCaptureEventMonitoring
    private var includeMicrophone = true
    private var recoveryAttempts = 0
    private let maximumRecoveryAttempts = 2
    private var resumeTask: Task<Void, Never>?

    var hasActiveOperation: Bool {
        isStarting || stopTask != nil || fullSession != nil || microphoneActive || systemActive
    }
    var isDraining: Bool {
        fullSession == nil && (submissionQueue.activeURL != nil || !submissionQueue.pendingURLs.isEmpty)
    }
    var canStart: Bool { !hasActiveOperation && !isDraining }
    var canStop: Bool { fullSession != nil && (microphoneActive || systemActive || state == .recovering) }

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
        eventMonitor: any AudioCaptureEventMonitoring = SystemAudioCaptureEventMonitor(),
        transcriber: any LiveAudioTranscribing,
        // Scheduler check cadence, not the chunk length itself: chunkRotationDecider decides the
        // actual cut point (energy-valley-aligned, 8s-30s bounded) each time this fires.
        flushInterval: TimeInterval = 1,
        chunkRotationDecider: ChunkRotationDecider = ChunkRotationDecider(),
        chunkOutputURLFactory: @escaping @Sendable () throws -> URL = {
            try MixedAudioRecordingController.makeChunkOutputURL()
        }
    ) {
        self.microphonePermission = microphonePermission
        self.screenPermission = screenPermission
        self.microphoneBackend = microphoneBackend
        self.systemBackend = systemBackend
        self.scheduler = scheduler
        self.eventMonitor = eventMonitor
        self.flushInterval = flushInterval
        self.chunkRotationDecider = chunkRotationDecider
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
        self.includeMicrophone = includeMicrophone
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
            eventMonitor.start { [weak self] event in self?.handleSystemEvent(event) }
            recoveryAttempts = 0
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
        resumeTask?.cancel()
        resumeTask = nil
        eventMonitor.stop()
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
            // The full session recording always receives every mixed sample immediately,
            // independent of chunk-cut decisions below.
            try fullSession.append(pcm)
            guard let readyChunk = chunkRotationDecider.append(pcm) else { return }
            try chunkSession.append(readyChunk)
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

    private func handleSystemEvent(_ event: AudioCaptureSystemEvent) {
        switch event {
        case .interruptionBegan:
            suspendCaptureForSleep()
        case .interruptionEnded:
            if state == .recovering { startResumeTask() }
        case .configurationChanged, .deviceChanged:
            // Mixed-mode device-change recovery is a known, separate gap — out of scope here.
            break
        }
    }

    private func suspendCaptureForSleep() {
        guard state == .recording else { return }
        state = .recovering
        scheduler.cancel()
        if microphoneActive {
            try? microphoneBackend.stop()
            microphoneActive = false
        }
        // Not awaiting systemBackend.stop() here: willSleepNotification's handler is dispatched
        // synchronously, so it cannot await. The OS force-tears-down the SCStream at sleep anyway;
        // the real stop-then-restart happens in resumeCaptureAfterSleep()'s async context, which
        // must stop() first to clear the dead stream reference (see known pitfalls).
        systemActive = false
    }

    private func startResumeTask() {
        resumeTask?.cancel()
        resumeTask = Task { [weak self] in
            await self?.resumeCaptureAfterSleep()
            self?.resumeTask = nil
        }
    }

    private func resumeCaptureAfterSleep() async {
        guard state == .recovering else { return }
        guard let accumulator else {
            failRecovery("Mixed audio session lost during recovery")
            return
        }
        guard submissionQueue.isWorkerReady else {
            failRecovery("Python Worker unavailable during audio recovery")
            return
        }
        // Must stop() first to clear ScreenCaptureKitAudioBackend's stale stream reference,
        // otherwise start()'s `guard stream == nil` silently no-ops and recovery fails quietly.
        try? await systemBackend.stop()
        let errorBox = MixedAudioErrorBox()
        self.errorBox = errorBox

        var lastError: Error?
        while recoveryAttempts < maximumRecoveryAttempts {
            guard !Task.isCancelled else { return }
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
                state = .recording
                recoveryAttempts = 0
                return
            } catch {
                lastError = error
                recoveryAttempts += 1
                if systemActive { try? await systemBackend.stop(); systemActive = false }
                if microphoneActive { try? microphoneBackend.stop(); microphoneActive = false }
            }
        }
        failRecovery("Mixed audio recovery failed: \(lastError?.localizedDescription ?? "unknown error")")
    }

    private func failRecovery(_ message: String) {
        resumeTask?.cancel()
        resumeTask = nil
        eventMonitor.stop()
        scheduler.cancel()
        if microphoneActive { try? microphoneBackend.stop(); microphoneActive = false }
        systemActive = false
        if !didFinalFlush { finalFlush(); didFinalFlush = true }
        if let fullSession, let url = try? fullSession.finalize() {
            lastFinalizedURL = url
        }
        self.fullSession = nil
        self.chunkSession = nil
        accumulator = nil
        errorBox = nil
        state = .failed(message)
    }

    private func finalFlush() {
        guard let accumulator, let chunkSession, let fullSession else { return }
        let pcm = accumulator.drain()
        do {
            if !pcm.isEmpty {
                try fullSession.append(pcm)
            }
            // Drain unconditionally: a residual chunk shorter than the 8s minimum must still be
            // transcribed on stop, not silently dropped (AC-B4).
            let remainder = chunkRotationDecider.drainRemainder() + pcm
            if !remainder.isEmpty {
                try chunkSession.append(remainder)
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
