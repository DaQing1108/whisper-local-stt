import Foundation
import Observation

enum LiveRecordingState: Equatable, Sendable {
    case idle
    case requestingPermission
    case recording
    case recovering
    case stopping
    case draining
    case failed(String)
}

private enum AudioRecoveryReason {
    case deviceChange
    case sleep
}

@MainActor
protocol LiveAudioTranscribing: AudioTranscribing {
    func addTerminalObserver(
        _ observer: @escaping @MainActor @Sendable (String?, String) -> Void
    ) -> UUID
    func addLostObserver(_ observer: @escaping @MainActor @Sendable (String) -> Void) -> UUID
    func addReadyObserver(_ observer: @escaping @MainActor @Sendable () -> Void) -> UUID
    func addUnavailableObserver(
        _ observer: @escaping @MainActor @Sendable (WorkerState) -> Void
    ) -> UUID
    func removeObserver(_ id: UUID)
}

extension WorkerSupervisor: LiveAudioTranscribing {}

final class RotatingCaptureSession: @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private let outputURLFactory: @Sendable () throws -> URL
    private var writer: PCM16WAVWriter

    init(outputURLFactory: @escaping @Sendable () throws -> URL) throws {
        self.outputURLFactory = outputURLFactory
        writer = try PCM16WAVWriter(url: outputURLFactory())
    }

    func append(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        try writer.append(data)
    }

    func rotate() throws -> URL? {
        lock.lock()
        defer { lock.unlock() }
        guard writer.hasAudioData else { return nil }
        let nextWriter = try PCM16WAVWriter(url: outputURLFactory())
        let finalized = try writer.finalize()
        writer = nextWriter
        return finalized
    }

    func finish() throws -> URL? {
        lock.lock()
        defer { lock.unlock() }
        let containsAudio = writer.hasAudioData
        let url = try writer.finalize()
        if !containsAudio { try? FileManager.default.removeItem(at: url) }
        return containsAudio ? url : nil
    }
}

@MainActor
protocol ChunkRotationScheduling: AnyObject {
    func schedule(every interval: TimeInterval, action: @escaping @MainActor @Sendable () -> Void)
    func cancel()
}

@MainActor
final class TimerChunkRotationScheduler: ChunkRotationScheduling {
    private var timer: Timer?

    func schedule(every interval: TimeInterval, action: @escaping @MainActor @Sendable () -> Void) {
        cancel()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in action() }
        }
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }
}

@MainActor
@Observable
final class OrderedChunkSubmissionQueue {
    private(set) var pendingURLs: [URL] = []
    private(set) var activeURL: URL?
    private(set) var activeRequestID: String?
    private(set) var completedURLs: [URL] = []
    private(set) var errorMessage: String?
    var modelName: String
    var language: String?
    var domain: String
    var extraTerms: String
    var queueDrainedHandler: (@MainActor @Sendable () -> Void)?
    var submissionFailureHandler: (@MainActor @Sendable (Error) -> Void)?

    private let transcriber: any LiveAudioTranscribing
    private var isPausedAfterFailure = false
    var isWorkerReady: Bool { transcriber.state == .ready }

    init(
        transcriber: any LiveAudioTranscribing, modelName: String,
        language: String? = nil, domain: String = "general", extraTerms: String = ""
    ) {
        self.transcriber = transcriber
        self.modelName = modelName
        self.language = language
        self.domain = domain
        self.extraTerms = extraTerms
        _ = transcriber.addTerminalObserver { [weak self] requestID, status in
            self?.jobDidReachTerminal(requestID: requestID, status: status)
        }
        _ = transcriber.addLostObserver { [weak self] requestID in
            self?.jobWasLost(requestID: requestID)
        }
        _ = transcriber.addReadyObserver { [weak self] in
            self?.isPausedAfterFailure = false
            self?.submitNextIfPossible()
        }
    }

    func enqueue(_ url: URL) {
        pendingURLs.append(url)
        submitNextIfPossible()
    }

    func preserveWithoutSubmitting(_ url: URL) {
        pendingURLs.append(url)
    }

    private func submitNextIfPossible() {
        guard !isPausedAfterFailure, activeURL == nil, !pendingURLs.isEmpty,
              transcriber.state == .ready else { return }
        let next = pendingURLs.removeFirst()
        do {
            activeRequestID = try transcriber.transcribe(
                audioURL: next, modelName: modelName, language: language,
                domain: domain, extraTerms: extraTerms
            )
            activeURL = next
            errorMessage = nil
        } catch {
            pendingURLs.insert(next, at: 0)
            isPausedAfterFailure = true
            errorMessage = error.localizedDescription
            submissionFailureHandler?(error)
        }
    }

    private func jobDidReachTerminal(requestID: String?, status: String) {
        guard requestID == activeRequestID else { return }
        guard status == "Completed" else {
            if let activeURL { pendingURLs.insert(activeURL, at: 0) }
            activeURL = nil
            activeRequestID = nil
            isPausedAfterFailure = true
            let error = ChunkSubmissionTerminalError(status: status)
            errorMessage = error.localizedDescription
            submissionFailureHandler?(error)
            return
        }
        if let activeURL { completedURLs.append(activeURL) }
        activeURL = nil
        activeRequestID = nil
        submitNextIfPossible()
        if activeURL == nil && pendingURLs.isEmpty { queueDrainedHandler?() }
    }

    private func jobWasLost(requestID: String) {
        guard requestID == activeRequestID, let activeURL else { return }
        pendingURLs.insert(activeURL, at: 0)
        self.activeURL = nil
        activeRequestID = nil
        submitNextIfPossible()
    }
}

private struct ChunkSubmissionTerminalError: LocalizedError {
    let status: String
    var errorDescription: String? { "Chunk transcription did not complete: \(status)" }
}

@MainActor
@Observable
final class LiveRecordingController {
    private(set) var state: LiveRecordingState = .idle
    private(set) var finalizedChunkURLs: [URL] = []
    private(set) var errorMessage: String?

    let submissionQueue: OrderedChunkSubmissionQueue
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
    private let permissionProvider: any MicrophonePermissionProviding
    private let backend: any AudioCaptureBackend
    private let scheduler: any ChunkRotationScheduling
    private let rotationInterval: TimeInterval
    private let outputURLFactory: @Sendable () throws -> URL
    private let eventMonitor: any AudioCaptureEventMonitoring
    private var session: RotatingCaptureSession?
    private var recoveryWatchdog: Task<Void, Never>?
    private var ignoreDeviceEventsUntil: Date?
    private var recoveryAttempts = 0
    private let maximumRecoveryAttempts = 2

    init(
        permissionProvider: any MicrophonePermissionProviding = SystemMicrophonePermissionProvider(),
        backend: any AudioCaptureBackend = AVAudioEngineCaptureBackend(),
        scheduler: any ChunkRotationScheduling = TimerChunkRotationScheduler(),
        eventMonitor: any AudioCaptureEventMonitoring = SystemAudioCaptureEventMonitor(),
        transcriber: any LiveAudioTranscribing,
        rotationInterval: TimeInterval = 15,
        modelName: String = "base",
        outputURLFactory: @escaping @Sendable () throws -> URL = {
            try LiveRecordingController.makeOutputURL()
        }
    ) {
        self.permissionProvider = permissionProvider
        self.backend = backend
        self.scheduler = scheduler
        self.eventMonitor = eventMonitor
        self.rotationInterval = rotationInterval
        self.outputURLFactory = outputURLFactory
        submissionQueue = OrderedChunkSubmissionQueue(transcriber: transcriber, modelName: modelName)
        submissionQueue.queueDrainedHandler = { [weak self] in
            if self?.state == .draining { self?.state = .idle }
        }
        submissionQueue.submissionFailureHandler = { [weak self] error in
            self?.submissionFailed(error)
        }
        _ = transcriber.addUnavailableObserver { [weak self] state in
            self?.workerBecameUnavailable(state)
        }
    }

    func start() async {
        guard state == .idle || isFailed else { return }
        ignoreDeviceEventsUntil = nil
        recoveryWatchdog?.cancel()
        recoveryWatchdog = nil
        guard submissionQueue.isWorkerReady else {
            fail("Python Worker must be ready before live mode starts")
            return
        }
        state = .requestingPermission
        let granted: Bool
        switch permissionProvider.status() {
        case .granted: granted = true
        case .notDetermined: granted = await permissionProvider.requestAccess()
        case .denied, .restricted: granted = false
        }
        guard granted else {
            fail("Microphone permission denied")
            return
        }
        do {
            try startCaptureSession()
            eventMonitor.start { [weak self] event in self?.handleSystemEvent(event) }
            recoveryAttempts = 0
            errorMessage = nil
        } catch {
            _ = try? session?.finish()
            self.session = nil
            fail(error.localizedDescription)
        }
    }

    func stop() {
        guard state == .recording || state == .recovering else { return }
        ignoreDeviceEventsUntil = nil
        recoveryWatchdog?.cancel()
        recoveryWatchdog = nil
        state = .stopping
        scheduler.cancel()
        eventMonitor.stop()
        guard let session else {
            state = submissionQueue.activeURL == nil && submissionQueue.pendingURLs.isEmpty ? .idle : .draining
            return
        }
        var stopError: Error?
        do {
            try backend.stop()
        } catch {
            stopError = error
        }
        do {
            if let finalURL = try session.finish() { acceptFinalizedChunk(finalURL) }
            self.session = nil
            if let stopError { throw stopError }
            state = submissionQueue.activeURL == nil && submissionQueue.pendingURLs.isEmpty ? .idle : .draining
        } catch {
            self.session = nil
            fail(error.localizedDescription)
        }
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    private func rotateChunk() {
        guard state == .recording, let session else { return }
        do {
            if let url = try session.rotate() { acceptFinalizedChunk(url) }
        }
        catch { captureFailed(error, sessionID: session.id) }
    }

    private func acceptFinalizedChunk(_ url: URL) {
        finalizedChunkURLs.append(url)
        submissionQueue.enqueue(url)
    }

    private func captureFailed(_ error: Error, sessionID: UUID?) {
        guard sessionID != nil, session?.id == sessionID else { return }
        recoveryWatchdog?.cancel()
        recoveryWatchdog = nil
        scheduler.cancel()
        let failedSession = session
        session = nil
        try? backend.stop()
        if let url = try? failedSession?.finish() { acceptFinalizedChunk(url) }
        fail(error.localizedDescription)
    }

    private func submissionFailed(_ error: Error) {
        recoveryWatchdog?.cancel()
        recoveryWatchdog = nil
        guard state == .recording, let session else {
            fail(error.localizedDescription)
            return
        }
        scheduler.cancel()
        try? backend.stop()
        if let url = try? session.finish() {
            finalizedChunkURLs.append(url)
            submissionQueue.preserveWithoutSubmitting(url)
        }
        self.session = nil
        fail(error.localizedDescription)
    }

    private func workerBecameUnavailable(_ workerState: WorkerState) {
        recoveryWatchdog?.cancel()
        recoveryWatchdog = nil
        switch state {
        case .recording, .stopping:
            scheduler.cancel()
            try? backend.stop()
            if let url = try? session?.finish() {
                finalizedChunkURLs.append(url)
                submissionQueue.preserveWithoutSubmitting(url)
            }
            session = nil
            fail("Python Worker unavailable: \(workerState)")
        case .draining:
            fail("Python Worker unavailable: \(workerState)")
        case .recovering:
            fail("Python Worker unavailable: \(workerState)")
        case .idle, .requestingPermission, .failed:
            break
        }
    }

    private func fail(_ message: String) {
        ignoreDeviceEventsUntil = nil
        recoveryWatchdog?.cancel()
        recoveryWatchdog = nil
        eventMonitor.stop()
        errorMessage = message
        state = .failed(message)
    }

    private func startCaptureSession() throws {
        let session = try RotatingCaptureSession(outputURLFactory: outputURLFactory)
        do {
            try backend.start(
                onPCM: { [weak self, session] data in
                    do { try session.append(data) }
                    catch { Task { @MainActor in self?.captureFailed(error, sessionID: session.id) } }
                },
                onError: { [weak self, session] error in
                    Task { @MainActor in self?.captureFailed(error, sessionID: session.id) }
                }
            )
        } catch {
            _ = try? session.finish()
            throw error
        }
        self.session = session
        scheduler.schedule(every: rotationInterval) { [weak self] in self?.rotateChunk() }
        state = .recording
    }

    private func handleSystemEvent(_ event: AudioCaptureSystemEvent) {
        switch event {
        case .interruptionBegan:
            suspendCaptureForRecovery(reason: .sleep)
        case .interruptionEnded:
            if state == .recovering { resumeCaptureAfterInterruption() }
        case .configurationChanged:
            if let ignoreDeviceEventsUntil, ignoreDeviceEventsUntil > Date() { return }
            handleDeviceEvent()
        case .deviceChanged:
            handleDeviceEvent()
        }
    }

    private func handleDeviceEvent() {
            if state == .recovering { scheduleRecoveryWatchdog() }
            else { suspendCaptureForRecovery(reason: .deviceChange) }
    }

    private func suspendCaptureForRecovery(reason: AudioRecoveryReason) {
        guard state == .recording else { return }
        state = .recovering
        scheduler.cancel()
        let interruptedSession = session
        session = nil
        try? backend.stop()
        if let url = try? interruptedSession?.finish() { acceptFinalizedChunk(url) }
        if case .deviceChange = reason {
            scheduleRecoveryWatchdog()
        }
    }

    private func resumeCaptureAfterInterruption() {
        recoveryWatchdog?.cancel()
        recoveryWatchdog = nil
        guard state == .recovering else { return }
        guard submissionQueue.isWorkerReady else {
            fail("Python Worker unavailable during audio recovery")
            return
        }
        var lastError: Error?
        while recoveryAttempts < maximumRecoveryAttempts {
            do {
                try startCaptureSession()
                ignoreDeviceEventsUntil = Date().addingTimeInterval(2)
                recoveryAttempts = 0
                return
            } catch {
                lastError = error
                recoveryAttempts += 1
            }
        }
        fail("Audio recovery failed: \(lastError?.localizedDescription ?? "unknown error")")
    }

    private func scheduleRecoveryWatchdog() {
        guard recoveryWatchdog == nil else { return }
        recoveryWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.recoveryWatchdog = nil
            self?.resumeCaptureAfterInterruption()
        }
    }

    nonisolated private static func makeOutputURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base
            .appendingPathComponent("WhisperSwiftUI", isDirectory: true)
            .appendingPathComponent("LiveChunks", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("chunk-\(UUID().uuidString).wav")
    }
}
