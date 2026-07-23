import Foundation
import Testing
@testable import WhisperApp

private struct LivePermissionProvider: MicrophonePermissionProviding {
    func status() -> MicrophonePermission { .granted }
    func requestAccess() async -> Bool { true }
}

private final class LiveCaptureBackend: AudioCaptureBackend, @unchecked Sendable {
    private var onPCM: (@Sendable (Data) -> Void)?
    var startError: Error?
    var stopError: Error?
    var failStartsAfterFirst = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    func start(
        onPCM: @escaping @Sendable (Data) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) throws {
        startCount += 1
        if failStartsAfterFirst && startCount > 1 { throw LiveTestError.simulated }
        if let startError { throw startError }
        self.onPCM = onPCM
    }
    func stop() throws {
        stopCount += 1
        if let stopError { throw stopError }
    }
    func emit(_ data: Data) { onPCM?(data) }
}

@MainActor
private final class ManualRotationScheduler: ChunkRotationScheduling {
    private var action: (@MainActor @Sendable () -> Void)?
    func schedule(every interval: TimeInterval, action: @escaping @MainActor @Sendable () -> Void) {
        self.action = action
    }
    func cancel() { action = nil }
    func fire() { action?() }
}

@MainActor
private final class ManualAudioEventMonitor: AudioCaptureEventMonitoring {
    private var handler: (@MainActor @Sendable (AudioCaptureSystemEvent) -> Void)?
    func start(handler: @escaping @MainActor @Sendable (AudioCaptureSystemEvent) -> Void) {
        self.handler = handler
    }
    func stop() { handler = nil }
    func emit(_ event: AudioCaptureSystemEvent) { handler?(event) }
}

@MainActor
private final class LiveTranscriber: LiveAudioTranscribing {
    var state: WorkerState = .ready
    private var terminalObservers: [UUID: @MainActor @Sendable (String?, String) -> Void] = [:]
    private var lostObservers: [UUID: @MainActor @Sendable (String) -> Void] = [:]
    private var readyObservers: [UUID: @MainActor @Sendable () -> Void] = [:]
    private var unavailableObservers: [UUID: @MainActor @Sendable (WorkerState) -> Void] = [:]
    private(set) var submittedURLs: [URL] = []
    private(set) var requestIDs: [String] = []
    private(set) var cancelCallCount = 0
    var transcribeError: Error?
    func cancel() throws { cancelCallCount += 1 }
    func transcribe(audioURL: URL, modelName: String, language: String?) throws -> String {
        if let transcribeError { throw transcribeError }
        submittedURLs.append(audioURL)
        let requestID = UUID().uuidString
        requestIDs.append(requestID)
        return requestID
    }
    func addTerminalObserver(_ observer: @escaping @MainActor @Sendable (String?, String) -> Void) -> UUID {
        let id = UUID(); terminalObservers[id] = observer; return id
    }
    func addLostObserver(_ observer: @escaping @MainActor @Sendable (String) -> Void) -> UUID {
        let id = UUID(); lostObservers[id] = observer; return id
    }
    func addReadyObserver(_ observer: @escaping @MainActor @Sendable () -> Void) -> UUID {
        let id = UUID(); readyObservers[id] = observer; return id
    }
    func addUnavailableObserver(_ observer: @escaping @MainActor @Sendable (WorkerState) -> Void) -> UUID {
        let id = UUID(); unavailableObservers[id] = observer; return id
    }
    func removeObserver(_ id: UUID) {
        terminalObservers[id] = nil; lostObservers[id] = nil
        readyObservers[id] = nil; unavailableObservers[id] = nil
    }
    func completeActiveJob() { terminalObservers.values.forEach { $0(requestIDs.last, "Completed") } }
    func failActiveJob(_ status: String = "Cancelled") {
        terminalObservers.values.forEach { $0(requestIDs.last, status) }
    }
    func emitUnrelatedTerminal() { terminalObservers.values.forEach { $0("unrelated", "Completed") } }
    func loseActiveJob() {
        state = .restarting(1)
        if let requestID = requestIDs.last { lostObservers.values.forEach { $0(requestID) } }
    }
    func becomeReady() {
        state = .ready
        readyObservers.values.forEach { $0() }
    }
    func becomePermanentlyUnavailable() {
        state = .failed("restart exhausted")
        if let requestID = requestIDs.last { lostObservers.values.forEach { $0(requestID) } }
        unavailableObservers.values.forEach { $0(state) }
    }
}

private enum LiveTestError: Error { case simulated }

private final class ChunkURLSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL]
    init(_ urls: [URL]) { self.urls = urls }
    func next() throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        return urls.removeFirst()
    }
}

@MainActor
struct LiveRecordingControllerTests {
    @Test
    func rotatesChunksAndSubmitsStrictlyInOrder() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = (1...3).map { directory.appendingPathComponent("chunk-\($0).wav") }
        let sequence = ChunkURLSequence(urls)
        let backend = LiveCaptureBackend()
        let scheduler = ManualRotationScheduler()
        let transcriber = LiveTranscriber()
        let controller = LiveRecordingController(
            permissionProvider: LivePermissionProvider(),
            backend: backend,
            scheduler: scheduler,
            transcriber: transcriber,
            rotationInterval: 15,
            modelName: "base",
            outputURLFactory: { try sequence.next() }
        )

        await controller.start()
        backend.emit(Data([0x01, 0x02]))
        scheduler.fire()
        backend.emit(Data([0x03, 0x04]))
        scheduler.fire()

        #expect(controller.finalizedChunkURLs == Array(urls.prefix(2)))
        #expect(transcriber.submittedURLs == [urls[0]])
        #expect(controller.submissionQueue.pendingURLs == [urls[1]])

        transcriber.emitUnrelatedTerminal()
        #expect(transcriber.submittedURLs == [urls[0]])
        #expect(controller.submissionQueue.pendingURLs == [urls[1]])

        transcriber.completeActiveJob()
        #expect(transcriber.submittedURLs == Array(urls.prefix(2)))
        controller.stop()
        #expect(controller.finalizedChunkURLs == Array(urls.prefix(2)))
        #expect(controller.state == .draining)

        transcriber.completeActiveJob()
        #expect(transcriber.submittedURLs == Array(urls.prefix(2)))
        #expect(controller.state == .idle)
        #expect(try Array(urls.prefix(2)).allSatisfy { try Data(contentsOf: $0).count == 46 })
    }

    @Test
    func submissionFailureStopsCaptureAndPreservesFinalizedChunk() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-failure-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = (1...2).map { directory.appendingPathComponent("chunk-\($0).wav") }
        let backend = LiveCaptureBackend()
        let scheduler = ManualRotationScheduler()
        let transcriber = LiveTranscriber()
        transcriber.transcribeError = LiveTestError.simulated
        let sequence = ChunkURLSequence(urls)
        let stableController = LiveRecordingController(
            permissionProvider: LivePermissionProvider(),
            backend: backend,
            scheduler: scheduler,
            transcriber: transcriber,
            outputURLFactory: { try sequence.next() }
        )
        await stableController.start()
        backend.emit(Data([0x01, 0x02]))
        scheduler.fire()

        if case .failed = stableController.state {} else { Issue.record("Expected failed state") }
        #expect(stableController.finalizedChunkURLs == [urls[0]])
        #expect(stableController.submissionQueue.pendingURLs == [urls[0]])
        #expect(FileManager.default.fileExists(atPath: urls[0].path))
    }

    @Test
    func stopErrorStillFinalizesAndTracksRecoveryChunk() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-stop-error-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("chunk.wav")
        let backend = LiveCaptureBackend()
        backend.stopError = LiveTestError.simulated
        let controller = LiveRecordingController(
            permissionProvider: LivePermissionProvider(),
            backend: backend,
            scheduler: ManualRotationScheduler(),
            transcriber: LiveTranscriber(),
            outputURLFactory: { url }
        )

        await controller.start()
        backend.emit(Data([0x01, 0x02]))
        controller.stop()

        if case .failed = controller.state {} else { Issue.record("Expected failed state") }
        #expect(controller.finalizedChunkURLs == [url])
        #expect(try Data(contentsOf: url).count == 46)
    }

    @Test
    func workerRestartRequeuesActiveChunkAndResumesInOrder() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-restart-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = (1...2).map { directory.appendingPathComponent("chunk-\($0).wav") }
        let sequence = ChunkURLSequence(urls)
        let backend = LiveCaptureBackend()
        let scheduler = ManualRotationScheduler()
        let transcriber = LiveTranscriber()
        let controller = LiveRecordingController(
            permissionProvider: LivePermissionProvider(),
            backend: backend,
            scheduler: scheduler,
            transcriber: transcriber,
            outputURLFactory: { try sequence.next() }
        )

        await controller.start()
        backend.emit(Data([0x01, 0x02]))
        scheduler.fire()
        #expect(transcriber.submittedURLs == [urls[0]])

        transcriber.loseActiveJob()
        #expect(controller.submissionQueue.activeURL == nil)
        #expect(controller.submissionQueue.pendingURLs == [urls[0]])
        transcriber.becomeReady()

        #expect(transcriber.submittedURLs == [urls[0], urls[0]])
        #expect(controller.submissionQueue.activeURL == urls[0])
        #expect(controller.finalizedChunkURLs == [urls[0]])
    }

    @Test
    func permanentWorkerFailureStopsCaptureAndPreservesAllChunks() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-worker-failed-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = (1...2).map { directory.appendingPathComponent("chunk-\($0).wav") }
        let sequence = ChunkURLSequence(urls)
        let backend = LiveCaptureBackend()
        let scheduler = ManualRotationScheduler()
        let transcriber = LiveTranscriber()
        let controller = LiveRecordingController(
            permissionProvider: LivePermissionProvider(),
            backend: backend,
            scheduler: scheduler,
            transcriber: transcriber,
            outputURLFactory: { try sequence.next() }
        )

        await controller.start()
        backend.emit(Data([0x01, 0x02]))
        scheduler.fire()
        backend.emit(Data([0x03, 0x04]))
        transcriber.becomePermanentlyUnavailable()

        if case .failed = controller.state {} else { Issue.record("Expected recoverable failed state") }
        #expect(controller.finalizedChunkURLs == urls)
        #expect(controller.submissionQueue.activeURL == nil)
        #expect(controller.submissionQueue.pendingURLs == urls)
        #expect(try urls.allSatisfy { try Data(contentsOf: $0).count == 46 })
    }

    @Test
    func deviceChangeFinalizesCurrentChunkAndResumesCapture() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-device-change-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = (1...2).map { directory.appendingPathComponent("chunk-\($0).wav") }
        let sequence = ChunkURLSequence(urls)
        let backend = LiveCaptureBackend()
        let monitor = ManualAudioEventMonitor()
        let controller = LiveRecordingController(
            permissionProvider: LivePermissionProvider(),
            backend: backend,
            scheduler: ManualRotationScheduler(),
            eventMonitor: monitor,
            transcriber: LiveTranscriber(),
            outputURLFactory: { try sequence.next() }
        )

        await controller.start()
        backend.emit(Data([0x01, 0x02]))
        monitor.emit(.deviceChanged)

        #expect(controller.state == .recovering)
        try await Task.sleep(for: .milliseconds(700))

        #expect(controller.state == .recording)
        #expect(controller.finalizedChunkURLs == [urls[0]])
        #expect(backend.startCount == 2)
        #expect(backend.stopCount == 1)
        #expect(try Data(contentsOf: urls[0]).count == 46)
    }

    @Test
    func sleepPausesAndWakeResumesWithoutLosingChunk() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-sleep-wake-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = (1...2).map { directory.appendingPathComponent("chunk-\($0).wav") }
        let sequence = ChunkURLSequence(urls)
        let backend = LiveCaptureBackend()
        let monitor = ManualAudioEventMonitor()
        let controller = LiveRecordingController(
            permissionProvider: LivePermissionProvider(),
            backend: backend,
            scheduler: ManualRotationScheduler(),
            eventMonitor: monitor,
            transcriber: LiveTranscriber(),
            outputURLFactory: { try sequence.next() }
        )

        await controller.start()
        backend.emit(Data([0x01, 0x02]))
        monitor.emit(.interruptionBegan)
        #expect(controller.state == .recovering)
        #expect(controller.finalizedChunkURLs == [urls[0]])
        monitor.emit(.interruptionEnded)

        #expect(controller.state == .recording)
        #expect(backend.startCount == 2)
    }

    @Test
    func deviceChangeResumesWhenNoMatchingEndEventArrives() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-interruption-watchdog-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = (1...2).map { directory.appendingPathComponent("chunk-\($0).wav") }
        let sequence = ChunkURLSequence(urls)
        let backend = LiveCaptureBackend()
        let monitor = ManualAudioEventMonitor()
        let controller = LiveRecordingController(
            permissionProvider: LivePermissionProvider(),
            backend: backend,
            scheduler: ManualRotationScheduler(),
            eventMonitor: monitor,
            transcriber: LiveTranscriber(),
            outputURLFactory: { try sequence.next() }
        )

        await controller.start()
        backend.emit(Data([0x01, 0x02]))
        monitor.emit(.deviceChanged)
        #expect(controller.state == .recovering)

        try await Task.sleep(for: .milliseconds(700))

        #expect(controller.state == .recording)
        #expect(controller.finalizedChunkURLs == [urls[0]])
        #expect(backend.startCount == 2)
    }

    @Test
    func repeatedDeviceEventsDebounceBeforeRestartingCapture() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-device-debounce-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = (1...2).map { directory.appendingPathComponent("chunk-\($0).wav") }
        let sequence = ChunkURLSequence(urls)
        let backend = LiveCaptureBackend()
        let monitor = ManualAudioEventMonitor()
        let controller = LiveRecordingController(
            permissionProvider: LivePermissionProvider(),
            backend: backend,
            scheduler: ManualRotationScheduler(),
            eventMonitor: monitor,
            transcriber: LiveTranscriber(),
            outputURLFactory: { try sequence.next() }
        )

        await controller.start()
        monitor.emit(.deviceChanged)
        monitor.emit(.configurationChanged)
        #expect(controller.state == .recovering)
        #expect(backend.startCount == 1)

        try await Task.sleep(for: .milliseconds(700))

        #expect(controller.state == .recording)
        #expect(backend.startCount == 2)
        #expect(controller.finalizedChunkURLs.isEmpty)
    }

    @Test
    func laterDeviceEventCannotIndefinitelyPostponeRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-device-bounded-debounce-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = (1...2).map { directory.appendingPathComponent("chunk-\($0).wav") }
        let sequence = ChunkURLSequence(urls)
        let backend = LiveCaptureBackend()
        let monitor = ManualAudioEventMonitor()
        let controller = LiveRecordingController(
            permissionProvider: LivePermissionProvider(),
            backend: backend,
            scheduler: ManualRotationScheduler(),
            eventMonitor: monitor,
            transcriber: LiveTranscriber(),
            outputURLFactory: { try sequence.next() }
        )

        await controller.start()
        monitor.emit(.deviceChanged)
        try await Task.sleep(for: .milliseconds(300))
        monitor.emit(.configurationChanged)
        try await Task.sleep(for: .milliseconds(300))

        #expect(controller.state == .recording)
        #expect(backend.startCount == 2)
    }

    @Test
    func sleepWaitsForWakeInsteadOfStartingTheDeviceRecoveryWatchdog() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-sleep-watchdog-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = (1...2).map { directory.appendingPathComponent("chunk-\($0).wav") }
        let sequence = ChunkURLSequence(urls)
        let backend = LiveCaptureBackend()
        let monitor = ManualAudioEventMonitor()
        let controller = LiveRecordingController(
            permissionProvider: LivePermissionProvider(),
            backend: backend,
            scheduler: ManualRotationScheduler(),
            eventMonitor: monitor,
            transcriber: LiveTranscriber(),
            outputURLFactory: { try sequence.next() }
        )

        await controller.start()
        monitor.emit(.interruptionBegan)
        try await Task.sleep(for: .milliseconds(700))

        #expect(controller.state == .recovering)
        #expect(backend.startCount == 1)
        monitor.emit(.interruptionEnded)
        #expect(controller.state == .recording)
        #expect(backend.startCount == 2)
    }

    @Test
    func repeatedDeviceRecoveryFailureStopsAfterBoundedAttempts() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-recovery-fail-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sequence = ChunkURLSequence((1...3).map { directory.appendingPathComponent("chunk-\($0).wav") })
        let backend = LiveCaptureBackend()
        backend.failStartsAfterFirst = true
        let monitor = ManualAudioEventMonitor()
        let controller = LiveRecordingController(
            permissionProvider: LivePermissionProvider(),
            backend: backend,
            scheduler: ManualRotationScheduler(),
            eventMonitor: monitor,
            transcriber: LiveTranscriber(),
            outputURLFactory: { try sequence.next() }
        )

        await controller.start()
        monitor.emit(.configurationChanged)
        try await Task.sleep(for: .milliseconds(700))

        if case .failed = controller.state {} else { Issue.record("Expected bounded recovery failure") }
        #expect(backend.startCount == 3)
    }

    @Test
    func simulatedLongRecordingPreservesAllChunkAndSubmissionOrder() async throws {
        let chunkCount = 120
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-long-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = (0...chunkCount).map { directory.appendingPathComponent("chunk-\($0).wav") }
        let sequence = ChunkURLSequence(urls)
        let backend = LiveCaptureBackend()
        let scheduler = ManualRotationScheduler()
        let transcriber = LiveTranscriber()
        let controller = LiveRecordingController(
            permissionProvider: LivePermissionProvider(),
            backend: backend,
            scheduler: scheduler,
            transcriber: transcriber,
            outputURLFactory: { try sequence.next() }
        )

        await controller.start()
        for _ in 0..<chunkCount {
            backend.emit(Data([0x01, 0x02, 0x03, 0x04]))
            scheduler.fire()
        }

        #expect(controller.finalizedChunkURLs == Array(urls.prefix(chunkCount)))
        #expect(transcriber.submittedURLs == [urls[0]])
        #expect(controller.submissionQueue.pendingURLs.count == chunkCount - 1)
        while transcriber.submittedURLs.count < chunkCount { transcriber.completeActiveJob() }
        transcriber.completeActiveJob()
        controller.stop()

        #expect(transcriber.submittedURLs == Array(urls.prefix(chunkCount)))
        #expect(controller.submissionQueue.pendingURLs.isEmpty)
        #expect(controller.submissionQueue.completedURLs == Array(urls.prefix(chunkCount)))
        #expect(controller.state == .idle)
        #expect(try controller.finalizedChunkURLs.allSatisfy { try Data(contentsOf: $0).count == 48 })
    }

    @Test
    func stalledJobWithNoTerminalEventTriggersCancelAfterTimeout() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-stall-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("chunk.wav")
        let backend = LiveCaptureBackend()
        let scheduler = ManualRotationScheduler()
        let transcriber = LiveTranscriber()
        let controller = LiveRecordingController(
            permissionProvider: LivePermissionProvider(),
            backend: backend,
            scheduler: scheduler,
            transcriber: transcriber,
            jobStallTimeout: 0.05,
            outputURLFactory: { url }
        )

        await controller.start()
        backend.emit(Data([0x01, 0x02]))
        scheduler.fire()
        #expect(transcriber.submittedURLs == [url])

        try await Task.sleep(for: .milliseconds(800))
        #expect(transcriber.cancelCallCount == 1)
    }

    @Test
    func jobCompletingBeforeTimeoutNeverTriggersCancel() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-no-stall-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("chunk.wav")
        let backend = LiveCaptureBackend()
        let scheduler = ManualRotationScheduler()
        let transcriber = LiveTranscriber()
        let controller = LiveRecordingController(
            permissionProvider: LivePermissionProvider(),
            backend: backend,
            scheduler: scheduler,
            transcriber: transcriber,
            jobStallTimeout: 0.05,
            outputURLFactory: { url }
        )

        await controller.start()
        backend.emit(Data([0x01, 0x02]))
        scheduler.fire()
        transcriber.completeActiveJob()

        try await Task.sleep(for: .milliseconds(800))
        #expect(transcriber.cancelCallCount == 0)
    }

    @Test
    func cancelledEventAfterStallRequeuesChunkAndPausesQueue() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-stall-cancelled-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("chunk.wav")
        let backend = LiveCaptureBackend()
        let scheduler = ManualRotationScheduler()
        let transcriber = LiveTranscriber()
        let controller = LiveRecordingController(
            permissionProvider: LivePermissionProvider(),
            backend: backend,
            scheduler: scheduler,
            transcriber: transcriber,
            jobStallTimeout: 0.05,
            outputURLFactory: { url }
        )

        await controller.start()
        backend.emit(Data([0x01, 0x02]))
        scheduler.fire()
        try await Task.sleep(for: .milliseconds(800))
        #expect(transcriber.cancelCallCount == 1)

        transcriber.failActiveJob("Cancelled")

        #expect(controller.submissionQueue.activeURL == nil)
        #expect(controller.submissionQueue.pendingURLs == [url])
        if case .failed = controller.state {} else { Issue.record("Expected failed state after stalled job was cancelled") }
    }

    @Test
    func acceptCompletedChunkAccumulatesAcrossThreeChunksWithIncreasingOffsets() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-accumulate-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = (1...3).map { directory.appendingPathComponent("chunk-\($0).wav") }
        let sequence = ChunkURLSequence(urls)
        let backend = LiveCaptureBackend()
        let scheduler = ManualRotationScheduler()
        let controller = LiveRecordingController(
            permissionProvider: LivePermissionProvider(),
            backend: backend,
            scheduler: scheduler,
            transcriber: LiveTranscriber(),
            rotationInterval: 15,
            outputURLFactory: { try sequence.next() }
        )
        await controller.start()
        backend.emit(Data([0x01, 0x02]))
        scheduler.fire()
        backend.emit(Data([0x03, 0x04]))
        scheduler.fire()
        backend.emit(Data([0x05, 0x06]))
        controller.stop()
        #expect(controller.finalizedChunkURLs == urls)

        #expect(controller.acceptCompletedChunk(urls[0], text: "第一段", durationSeconds: 15))
        #expect(controller.transcriptText.contains("第一段"))
        #expect(controller.transcriptDurationSeconds == 15)

        #expect(controller.acceptCompletedChunk(urls[1], text: "第二段", durationSeconds: 15))
        #expect(controller.transcriptText.contains("第一段"))
        #expect(controller.transcriptText.contains("第二段"))
        #expect(controller.transcriptDurationSeconds == 30)
        #expect(controller.transcriptSegments.last?.start == 15)
        #expect(controller.transcriptSegments.last?.end == 30)

        #expect(controller.acceptCompletedChunk(urls[2], text: "第三段", durationSeconds: 15))
        #expect(controller.transcriptText.contains("第三段"))
        #expect(controller.transcriptDurationSeconds == 45)
        #expect(controller.transcriptSegments.last?.start == 30)
        #expect(controller.transcriptSegments.last?.end == 45)
    }

    @Test
    func acceptCompletedChunkIgnoresDuplicateSubmissionForSameURL() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-dedup-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("chunk-1.wav")
        let backend = LiveCaptureBackend()
        let controller = LiveRecordingController(
            permissionProvider: LivePermissionProvider(),
            backend: backend,
            scheduler: ManualRotationScheduler(),
            transcriber: LiveTranscriber(),
            outputURLFactory: { url }
        )
        await controller.start()
        backend.emit(Data([0x01, 0x02]))
        controller.stop()
        #expect(controller.finalizedChunkURLs == [url])

        #expect(controller.acceptCompletedChunk(url, text: "第一段", durationSeconds: 15))
        #expect(controller.transcriptDurationSeconds == 15)
        #expect(!controller.acceptCompletedChunk(url, text: "重複", durationSeconds: 15))
        #expect(controller.transcriptDurationSeconds == 15)
        #expect(!controller.transcriptText.contains("重複"))
    }

    @Test
    func ownsChunkReturnsFalseForURLNotFinalizedByThisController() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-not-owned-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let unrelatedURL = directory.appendingPathComponent("unrelated.wav")
        let controller = LiveRecordingController(
            permissionProvider: LivePermissionProvider(),
            backend: LiveCaptureBackend(),
            scheduler: ManualRotationScheduler(),
            transcriber: LiveTranscriber()
        )

        #expect(!controller.ownsChunk(unrelatedURL))
        #expect(!controller.acceptCompletedChunk(unrelatedURL, text: "不屬於這個 controller"))
    }
}
