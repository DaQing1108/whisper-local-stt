import Foundation
import Testing
@testable import WhisperApp

private struct MixedMicrophonePermission: MicrophonePermissionProviding {
    let granted: Bool
    func status() -> MicrophonePermission { granted ? .granted : .denied }
    func requestAccess() async -> Bool { granted }
}

private struct MixedScreenPermission: ScreenRecordingPermissionProviding {
    let granted: Bool
    func preflight() -> Bool { granted }
    func request() -> Bool { granted }
}

private final class MixedMicrophoneBackend: AudioCaptureBackend, @unchecked Sendable {
    var startError: Error?
    private var pcm: (@Sendable (Data) -> Void)?
    private var error: (@Sendable (Error) -> Void)?
    private(set) var stopCount = 0
    func start(onPCM: @escaping @Sendable (Data) -> Void, onError: @escaping @Sendable (Error) -> Void) throws {
        if let startError { throw startError }
        pcm = onPCM
        self.error = onError
    }
    func stop() throws { stopCount += 1 }
    func emit(_ samples: [Int16]) { pcm?(samples.pcmData) }
    func emitError(_ value: Error) { error?(value) }
}

@MainActor
private final class MixedSystemBackend: SystemAudioCaptureBackend {
    private var pcm: (@Sendable (Data) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    var suspendStart = false
    var suspendStop = false
    var stopError: Error?
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var stopContinuation: CheckedContinuation<Void, Never>?
    func start() async throws {
        startCount += 1
        if suspendStart { await withCheckedContinuation { startContinuation = $0 } }
    }
    func stop() async throws {
        stopCount += 1
        if suspendStop { await withCheckedContinuation { stopContinuation = $0 } }
        if let stopError { throw stopError }
    }
    func setErrorHandler(_ handler: @escaping @MainActor @Sendable (Error) -> Void) {}
    func setPCMHandler(_ handler: @escaping @Sendable (Data) -> Void) { pcm = handler }
    func emit(_ samples: [Int16]) { pcm?(samples.pcmData) }
    func resumeStart() { startContinuation?.resume(); startContinuation = nil }
    func resumeStop() { stopContinuation?.resume(); stopContinuation = nil }
}

@MainActor
private final class MixedScheduler: ChunkRotationScheduling {
    private var action: (@MainActor @Sendable () -> Void)?
    func schedule(every interval: TimeInterval, action: @escaping @MainActor @Sendable () -> Void) { self.action = action }
    func cancel() { action = nil }
    func fire() { action?() }
}

@MainActor
private final class MixedTranscriber: LiveAudioTranscribing {
    var state: WorkerState = .ready
    private var terminalObservers: [UUID: @MainActor @Sendable (String?, String) -> Void] = [:]
    private var lostObservers: [UUID: @MainActor @Sendable (String) -> Void] = [:]
    private var readyObservers: [UUID: @MainActor @Sendable () -> Void] = [:]
    private var unavailableObservers: [UUID: @MainActor @Sendable (WorkerState) -> Void] = [:]
    private(set) var submittedURLs: [URL] = []
    private(set) var requestIDs: [String] = []
    var transcribeError: Error?
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
    func completeJob(at index: Int, status: String = "Completed") {
        guard requestIDs.indices.contains(index) else { return }
        terminalObservers.values.forEach { $0(requestIDs[index], status) }
    }
    func completeActiveJob() { terminalObservers.values.forEach { $0(requestIDs.last, "Completed") } }
}

private enum MixedTestError: Error { case failed }

private extension Array where Element == Int16 {
    var pcmData: Data {
        withUnsafeBytes { Data($0) }
    }
}

@MainActor
struct MixedAudioRecordingControllerTests {
    @Test
    func rotatesChunksAndSubmitsInOrderThenFinalizesLastPartialChunkOnStop() async throws {
        let mic = MixedMicrophoneBackend()
        let system = MixedSystemBackend()
        let scheduler = MixedScheduler()
        let transcriber = MixedTranscriber()
        let controller = MixedAudioRecordingController(
            microphonePermission: MixedMicrophonePermission(granted: true),
            screenPermission: SystemAudioPermissionController(provider: MixedScreenPermission(granted: true)),
            microphoneBackend: mic,
            systemBackend: system,
            scheduler: scheduler,
            transcriber: transcriber
        )
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mixed-\(UUID()).wav")

        try await controller.start(outputURL: url)
        mic.emit([1000, 3000])
        system.emit([3000, 1000])
        scheduler.fire()
        #expect(controller.finalizedChunkURLs.count == 1)
        #expect(transcriber.submittedURLs.count == 1)
        #expect(transcriber.submittedURLs.first == controller.finalizedChunkURLs.first)

        mic.emit([5000, 9000])
        system.emit([1000, 2000])
        scheduler.fire()
        // Second chunk queues behind the first, which is still in flight.
        #expect(controller.finalizedChunkURLs.count == 2)
        #expect(transcriber.submittedURLs.count == 1)
        #expect(controller.submissionQueue.pendingURLs.count == 1)

        transcriber.completeJob(at: 0)
        #expect(transcriber.submittedURLs.count == 2)

        mic.emit([50, 60])
        system.emit([10, 20])
        let finalized = try await controller.stopAndTranscribe(modelName: "base")
        #expect(finalized == url)
        #expect(controller.finalizedChunkURLs.count == 3)
        #expect(mic.stopCount == 1)
        #expect(system.stopCount == 1)
        try? FileManager.default.removeItem(at: url)
        for chunkURL in controller.finalizedChunkURLs { try? FileManager.default.removeItem(at: chunkURL) }
    }

    @Test
    func silentMixedChunkIsSkippedButDurationStillAdvances() async throws {
        let mic = MixedMicrophoneBackend()
        let system = MixedSystemBackend()
        let scheduler = MixedScheduler()
        let transcriber = MixedTranscriber()
        let controller = MixedAudioRecordingController(
            microphonePermission: MixedMicrophonePermission(granted: true),
            screenPermission: SystemAudioPermissionController(provider: MixedScreenPermission(granted: true)),
            microphoneBackend: mic,
            systemBackend: system,
            scheduler: scheduler,
            transcriber: transcriber,
            flushInterval: 15
        )
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mixed-silent-\(UUID()).wav")
        try await controller.start(outputURL: url)
        defer {
            try? FileManager.default.removeItem(at: url)
            for chunkURL in controller.finalizedChunkURLs { try? FileManager.default.removeItem(at: chunkURL) }
        }

        mic.emit(Array(repeating: Int16(5), count: 50))
        system.emit(Array(repeating: Int16(5), count: 50))
        scheduler.fire()

        #expect(controller.finalizedChunkURLs.count == 1)
        #expect(transcriber.submittedURLs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: controller.finalizedChunkURLs[0].path))
        // Duration reflects the mixed chunk's actual 50-sample content (50/16000s), not the
        // nominal 15s flush interval.
        #expect(controller.transcriptDurationSeconds == Double(50) / 16_000)

        mic.emit(Array(repeating: Int16(12_000), count: 50))
        system.emit(Array(repeating: Int16(12_000), count: 50))
        scheduler.fire()
        transcriber.completeActiveJob()

        #expect(transcriber.submittedURLs == [controller.finalizedChunkURLs[1]])
    }

    @Test
    func partialSilentMixedChunkFromStopAdvancesDurationByItsActualLengthNotFlushInterval() async throws {
        // finalFlush() (triggered by stop, before any scheduler.fire()) produces a chunk
        // shorter than flushInterval. A silent chunk like this must be credited with its
        // true length, not the full 15s, or later segment timestamps would drift.
        let mic = MixedMicrophoneBackend()
        let system = MixedSystemBackend()
        let scheduler = MixedScheduler()
        let transcriber = MixedTranscriber()
        let controller = MixedAudioRecordingController(
            microphonePermission: MixedMicrophonePermission(granted: true),
            screenPermission: SystemAudioPermissionController(provider: MixedScreenPermission(granted: true)),
            microphoneBackend: mic,
            systemBackend: system,
            scheduler: scheduler,
            transcriber: transcriber,
            flushInterval: 15
        )
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mixed-partial-silent-\(UUID()).wav")
        try await controller.start(outputURL: url)
        defer {
            try? FileManager.default.removeItem(at: url)
            for chunkURL in controller.finalizedChunkURLs { try? FileManager.default.removeItem(at: chunkURL) }
        }

        // 4,000 samples at 16kHz mono = 0.25s, well short of the 15s flush interval.
        mic.emit(Array(repeating: Int16(5), count: 4_000))
        // No scheduler.fire(): stop() finalizes the in-progress chunk via finalFlush().

        _ = try await controller.stop()

        #expect(transcriber.submittedURLs.isEmpty)
        #expect(controller.transcriptDurationSeconds == 0.25)
    }

    @Test
    func acceptCompletedChunkAccumulatesCumulativeTranscriptWithOffsets() async throws {
        let mic = MixedMicrophoneBackend()
        let system = MixedSystemBackend()
        let scheduler = MixedScheduler()
        let transcriber = MixedTranscriber()
        let controller = MixedAudioRecordingController(
            microphonePermission: MixedMicrophonePermission(granted: true),
            screenPermission: SystemAudioPermissionController(provider: MixedScreenPermission(granted: true)),
            microphoneBackend: mic,
            systemBackend: system,
            scheduler: scheduler,
            transcriber: transcriber,
            flushInterval: 15
        )
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mixed-cumulative-\(UUID()).wav")
        try await controller.start(outputURL: url)
        mic.emit([1000, 3000])
        system.emit([3000, 1000])
        scheduler.fire()
        let firstChunkURL = controller.finalizedChunkURLs[0]

        #expect(controller.acceptCompletedChunk(
            firstChunkURL, text: "第一段",
            segments: [TranscriptionSegment(start: 0, end: 4, text: "第一段")],
            durationSeconds: 4
        ))
        #expect(controller.transcriptDurationSeconds == 4)
        #expect(controller.transcriptText.contains("第一段"))

        mic.emit([2000, 4000])
        system.emit([1000, 2000])
        scheduler.fire()
        let secondChunkURL = controller.finalizedChunkURLs[1]
        #expect(controller.acceptCompletedChunk(
            secondChunkURL, text: "第二段",
            segments: [TranscriptionSegment(start: 0, end: 3, text: "第二段")],
            durationSeconds: 3
        ))
        // Second chunk's segment offsets must be shifted by the first chunk's cumulative duration.
        #expect(controller.transcriptDurationSeconds == 7)
        #expect(controller.transcriptSegments.last?.start == 4)
        #expect(controller.transcriptSegments.last?.end == 7)

        // Re-accepting the same chunk URL must not double-count.
        #expect(!controller.acceptCompletedChunk(secondChunkURL, text: "第二段"))
        #expect(controller.transcriptDurationSeconds == 7)

        _ = try? await controller.stop()
        try? FileManager.default.removeItem(at: url)
        for chunkURL in controller.finalizedChunkURLs { try? FileManager.default.removeItem(at: chunkURL) }
    }

    @Test
    func microphoneStartFailureRollsBackSystemCapture() async {
        let mic = MixedMicrophoneBackend()
        mic.startError = MixedTestError.failed
        let system = MixedSystemBackend()
        let controller = MixedAudioRecordingController(
            microphonePermission: MixedMicrophonePermission(granted: true),
            screenPermission: SystemAudioPermissionController(provider: MixedScreenPermission(granted: true)),
            microphoneBackend: mic,
            systemBackend: system,
            scheduler: MixedScheduler(),
            transcriber: MixedTranscriber()
        )
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mixed-fail-\(UUID()).wav")

        await #expect(throws: (any Error).self) { try await controller.start(outputURL: url) }
        #expect(system.startCount == 1)
        #expect(system.stopCount == 1)
        #expect(controller.state.isFailed)
        try? FileManager.default.removeItem(at: url)
    }

    @Test
    func stopDuringStartWaitsForStartAndConcurrentStopsShareOneDrain() async throws {
        let mic = MixedMicrophoneBackend()
        let system = MixedSystemBackend()
        system.suspendStart = true
        let controller = MixedAudioRecordingController(
            microphonePermission: MixedMicrophonePermission(granted: true),
            screenPermission: SystemAudioPermissionController(provider: MixedScreenPermission(granted: true)),
            microphoneBackend: mic,
            systemBackend: system,
            scheduler: MixedScheduler(),
            transcriber: MixedTranscriber()
        )
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mixed-race-\(UUID()).wav")
        let start = Task { try await controller.start(outputURL: url) }
        await Task.yield()
        let firstStop = Task { try await controller.stop() }
        let secondStop = Task { try await controller.stop() }
        await Task.yield()
        system.resumeStart()
        try await start.value
        let firstURL = try await firstStop.value
        let secondURL = try await secondStop.value

        #expect(firstURL == secondURL)
        #expect(system.stopCount == 1)
        #expect(mic.stopCount == 1)
        #expect(controller.canStart)
        try? FileManager.default.removeItem(at: url)
    }

    @Test
    func rollbackStopFailureRetainsCleanupHandleForRetry() async {
        let mic = MixedMicrophoneBackend()
        mic.startError = MixedTestError.failed
        let system = MixedSystemBackend()
        system.stopError = MixedTestError.failed
        let controller = MixedAudioRecordingController(
            microphonePermission: MixedMicrophonePermission(granted: true),
            screenPermission: SystemAudioPermissionController(provider: MixedScreenPermission(granted: true)),
            microphoneBackend: mic,
            systemBackend: system,
            scheduler: MixedScheduler(),
            transcriber: MixedTranscriber()
        )
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mixed-cleanup-\(UUID()).wav")
        await #expect(throws: (any Error).self) { try await controller.start(outputURL: url) }
        #expect(controller.canStop)
        system.stopError = nil
        _ = try? await controller.stop()
        #expect(system.stopCount == 2)
        #expect(controller.canStart)
        try? FileManager.default.removeItem(at: url)
    }

    @Test
    func midRecordingStopFailureThenSuccessfulRetryDoesNotDeleteTheRecording() async throws {
        let mic = MixedMicrophoneBackend()
        let system = MixedSystemBackend()
        let scheduler = MixedScheduler()
        let transcriber = MixedTranscriber()
        let controller = MixedAudioRecordingController(
            microphonePermission: MixedMicrophonePermission(granted: true),
            screenPermission: SystemAudioPermissionController(provider: MixedScreenPermission(granted: true)),
            microphoneBackend: mic,
            systemBackend: system,
            scheduler: scheduler,
            transcriber: transcriber
        )
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mixed-retry-\(UUID()).wav")
        try await controller.start(outputURL: url)
        mic.emit([1000, 3000])
        system.emit([3000, 1000])
        scheduler.fire()
        #expect(controller.finalizedChunkURLs.count == 1)

        // A genuine mid-recording stop failure (not a start-rollback failure) must not corrupt state:
        // finalFlush() runs once during this attempt and must not run again on retry.
        system.stopError = MixedTestError.failed
        await #expect(throws: (any Error).self) { try await controller.stop() }
        #expect(controller.canStop)

        system.stopError = nil
        let finalized = try await controller.stop()
        #expect(finalized == url)
        #expect(system.stopCount == 2)
        #expect(FileManager.default.fileExists(atPath: url.path))
        let bytes = try Data(contentsOf: url)
        #expect(bytes.count > 44)

        // Complete the still-draining chunk submitted before stop() to confirm the controller
        // becomes restart-ready once transcription genuinely finishes, not just after stop() returns.
        transcriber.completeJob(at: 0)
        #expect(controller.canStart)

        try? FileManager.default.removeItem(at: url)
        for chunkURL in controller.finalizedChunkURLs { try? FileManager.default.removeItem(at: chunkURL) }
    }

    @Test
    func startWhileSubmissionQueueIsStillDrainingIsBlockedUntilItCompletes() async throws {
        let mic = MixedMicrophoneBackend()
        let system = MixedSystemBackend()
        let scheduler = MixedScheduler()
        let transcriber = MixedTranscriber()
        let controller = MixedAudioRecordingController(
            microphonePermission: MixedMicrophonePermission(granted: true),
            screenPermission: SystemAudioPermissionController(provider: MixedScreenPermission(granted: true)),
            microphoneBackend: mic,
            systemBackend: system,
            scheduler: scheduler,
            transcriber: transcriber
        )
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mixed-drain-\(UUID()).wav")
        try await controller.start(outputURL: url)
        mic.emit([1000, 3000])
        system.emit([3000, 1000])
        scheduler.fire()
        _ = try await controller.stopAndTranscribe(modelName: "base")
        #expect(controller.isDraining)
        #expect(!controller.canStart)

        let restartURL = FileManager.default.temporaryDirectory.appendingPathComponent("mixed-drain-2-\(UUID()).wav")
        await #expect(throws: (any Error).self) { try await controller.start(outputURL: restartURL) }

        transcriber.completeJob(at: 0)
        #expect(!controller.isDraining)
        #expect(controller.canStart)

        try await controller.start(outputURL: restartURL)
        _ = try? await controller.stop()

        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: restartURL)
        for chunkURL in controller.finalizedChunkURLs { try? FileManager.default.removeItem(at: chunkURL) }
    }

    @Test
    func drainedTerminalErrorDiscardsSessionWithoutBlockingRestart() async throws {
        let mic = MixedMicrophoneBackend()
        let system = MixedSystemBackend()
        let controller = MixedAudioRecordingController(
            microphonePermission: MixedMicrophonePermission(granted: true),
            screenPermission: SystemAudioPermissionController(provider: MixedScreenPermission(granted: true)),
            microphoneBackend: mic,
            systemBackend: system,
            scheduler: MixedScheduler(),
            transcriber: MixedTranscriber()
        )
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mixed-error-\(UUID()).wav")
        try await controller.start(outputURL: url)
        mic.emitError(MixedTestError.failed)
        await #expect(throws: (any Error).self) { try await controller.stop() }
        #expect(controller.canStart)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

private extension MixedAudioRecordingState {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}
