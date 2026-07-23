import Foundation
import Testing
@testable import WhisperApp

private struct SystemLivePermissionProvider: ScreenRecordingPermissionProviding {
    func preflight() -> Bool { true }
    func request() -> Bool { true }
}

@MainActor
private final class SystemLiveCaptureBackend: SystemAudioCaptureBackend {
    private var pcmHandler: (@Sendable (Data) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    func start() async throws { startCount += 1 }
    func stop() async throws { stopCount += 1 }
    func setErrorHandler(_ handler: @escaping @MainActor @Sendable (Error) -> Void) {}
    func setPCMHandler(_ handler: @escaping @Sendable (Data) -> Void) { pcmHandler = handler }
    func emitPCM(_ data: Data) { pcmHandler?(data) }
}

@MainActor
private final class SystemLiveTranscriber: LiveAudioTranscribing {
    var state: WorkerState = .ready
    private var terminalObservers: [UUID: @MainActor @Sendable (String?, String) -> Void] = [:]
    private(set) var submittedURLs: [URL] = []
    private(set) var submittedModelNames: [String] = []
    private(set) var submittedLanguages: [String?] = []
    private(set) var requestIDs: [String] = []

    func cancel() throws {}
    func transcribe(audioURL: URL, modelName: String, language: String?) throws -> String {
        submittedURLs.append(audioURL)
        submittedModelNames.append(modelName)
        submittedLanguages.append(language)
        let requestID = UUID().uuidString
        requestIDs.append(requestID)
        return requestID
    }

    func addTerminalObserver(_ observer: @escaping @MainActor @Sendable (String?, String) -> Void) -> UUID {
        let id = UUID(); terminalObservers[id] = observer; return id
    }
    func addLostObserver(_ observer: @escaping @MainActor @Sendable (String) -> Void) -> UUID { UUID() }
    func addReadyObserver(_ observer: @escaping @MainActor @Sendable () -> Void) -> UUID { UUID() }
    func addUnavailableObserver(_ observer: @escaping @MainActor @Sendable (WorkerState) -> Void) -> UUID { UUID() }
    func removeObserver(_ id: UUID) { terminalObservers[id] = nil }
    func completeActiveJob() { terminalObservers.values.forEach { $0(requestIDs.last, "Completed") } }
    func failActiveJob(_ status: String = "disk model failure") {
        terminalObservers.values.forEach { $0(requestIDs.last, status) }
    }
}

@MainActor
private final class SystemLiveScheduler: ChunkRotationScheduling {
    private var action: (@MainActor @Sendable () -> Void)?
    func schedule(every interval: TimeInterval, action: @escaping @MainActor @Sendable () -> Void) {
        #expect(interval == 15)
        self.action = action
    }
    func cancel() { action = nil }
    func fire() { action?() }
}

private final class SystemLiveURLSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL]
    init(_ urls: [URL]) { self.urls = urls }
    func next() throws -> URL {
        lock.lock(); defer { lock.unlock() }
        guard !urls.isEmpty else {
            throw CocoaError(.fileNoSuchFile)
        }
        return urls.removeFirst()
    }
}

@MainActor
struct SystemAudioLiveRecordingControllerTests {
    @Test
    func stopAfterDrainedChunkAndSilenceReturnsSessionAndCleansChunk() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("system-live-silent-stop-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = (1...2).map { directory.appendingPathComponent("chunk-\($0).wav") }
        let sequence = SystemLiveURLSequence(urls)
        let permission = SystemAudioPermissionController(provider: SystemLivePermissionProvider())
        permission.refresh()
        let backend = SystemLiveCaptureBackend()
        let scheduler = SystemLiveScheduler()
        let transcriber = SystemLiveTranscriber()
        let controller = SystemAudioRecordingController(
            lifecycle: SystemAudioCaptureLifecycleController(permission: permission, backend: backend),
            backend: backend, transcriber: transcriber, scheduler: scheduler,
            outputURLFactory: { try sequence.next() }
        )

        try await controller.start()
        backend.emitPCM(Data([0x01, 0x02]))
        scheduler.fire()
        transcriber.completeActiveJob()
        #expect(FileManager.default.fileExists(atPath: urls[0].path))

        let returned = try await controller.stopAndTranscribe(modelName: "base")
        #expect(returned == controller.sessionFinalizedURL)
        #expect(FileManager.default.fileExists(atPath: returned.path))
        #expect(!FileManager.default.fileExists(atPath: urls[0].path))
    }

    @Test
    func entireSessionSilentStillFinalizesSessionWithEmptyTranscript() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("system-live-all-silent-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = (1...2).map { directory.appendingPathComponent("chunk-\($0).wav") }
        let sequence = SystemLiveURLSequence(urls)
        let permission = SystemAudioPermissionController(provider: SystemLivePermissionProvider())
        permission.refresh()
        let backend = SystemLiveCaptureBackend()
        let scheduler = SystemLiveScheduler()
        let transcriber = SystemLiveTranscriber()
        let controller = SystemAudioRecordingController(
            lifecycle: SystemAudioCaptureLifecycleController(permission: permission, backend: backend),
            backend: backend, transcriber: transcriber, scheduler: scheduler,
            outputURLFactory: { try sequence.next() }
        )

        try await controller.start()
        var quietSamples = Data()
        for _ in 0..<50 {
            var value: Int16 = 5
            withUnsafeBytes(of: &value) { quietSamples.append(contentsOf: $0) }
        }
        backend.emitPCM(quietSamples)
        scheduler.fire()
        #expect(transcriber.submittedURLs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: urls[0].path))

        let returned = try await controller.stopAndTranscribe(modelName: "base")
        #expect(returned == controller.sessionFinalizedURL)
        #expect(FileManager.default.fileExists(atPath: returned.path))
        #expect(controller.transcriptText.isEmpty)
        // Duration reflects the chunk's actual 50-sample content (50/16000s), not the nominal
        // 15s rotation interval — rotate() finalizes whatever was accumulated, not a full chunk.
        #expect(controller.transcriptDurationSeconds == Double(50) / 16_000)
        #expect(transcriber.submittedURLs.isEmpty)
    }

    @Test
    func silentChunkIsSkippedButDurationStillAdvances() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("system-live-silent-skip-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = (1...3).map { directory.appendingPathComponent("chunk-\($0).wav") }
        let sequence = SystemLiveURLSequence(urls)
        let permission = SystemAudioPermissionController(provider: SystemLivePermissionProvider())
        permission.refresh()
        let backend = SystemLiveCaptureBackend()
        let scheduler = SystemLiveScheduler()
        let transcriber = SystemLiveTranscriber()
        let controller = SystemAudioRecordingController(
            lifecycle: SystemAudioCaptureLifecycleController(permission: permission, backend: backend),
            backend: backend, transcriber: transcriber, scheduler: scheduler,
            outputURLFactory: { try sequence.next() }
        )

        try await controller.start()

        var quietSamples = Data()
        for _ in 0..<50 {
            var value: Int16 = 5
            withUnsafeBytes(of: &value) { quietSamples.append(contentsOf: $0) }
        }
        backend.emitPCM(quietSamples)
        scheduler.fire()

        #expect(transcriber.submittedURLs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: urls[0].path))
        #expect(controller.transcriptDurationSeconds == Double(50) / 16_000)

        var loudSamples = Data()
        for _ in 0..<50 {
            var value: Int16 = 12_000
            withUnsafeBytes(of: &value) { loudSamples.append(contentsOf: $0) }
        }
        backend.emitPCM(loudSamples)
        scheduler.fire()
        transcriber.completeActiveJob()

        #expect(transcriber.submittedURLs == [urls[1]])
    }

    @Test
    func partialSilentChunkFromStopAdvancesDurationByItsActualLengthNotRotationInterval() async throws {
        // session.finish() (triggered by stop, before any rotation fires) produces a chunk
        // shorter than rotationInterval. If a silent chunk like this were credited with the
        // full 15s rotation interval instead of its true length, every later segment's
        // timestamp would drift by the difference.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("system-live-partial-silent-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = [directory.appendingPathComponent("chunk-1.wav")]
        let sequence = SystemLiveURLSequence(urls)
        let permission = SystemAudioPermissionController(provider: SystemLivePermissionProvider())
        permission.refresh()
        let backend = SystemLiveCaptureBackend()
        let scheduler = SystemLiveScheduler()
        let transcriber = SystemLiveTranscriber()
        let controller = SystemAudioRecordingController(
            lifecycle: SystemAudioCaptureLifecycleController(permission: permission, backend: backend),
            backend: backend, transcriber: transcriber, scheduler: scheduler,
            outputURLFactory: { try sequence.next() }
        )

        try await controller.start()
        // 8,000 samples at 16kHz mono = 0.5s, well short of the 15s rotation interval.
        var quietSamples = Data()
        for _ in 0..<8_000 {
            var value: Int16 = 5
            withUnsafeBytes(of: &value) { quietSamples.append(contentsOf: $0) }
        }
        backend.emitPCM(quietSamples)
        // No scheduler.fire(): stop() finalizes the in-progress chunk via session.finish().

        _ = try await controller.stopAndTranscribe(modelName: "base")

        #expect(transcriber.submittedURLs.isEmpty)
        #expect(controller.transcriptDurationSeconds == 0.5)
    }

    @Test
    func rotationFailureStopsCaptureAndFinalizesCurrentAudio() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("system-live-rotate-failure-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("chunk-1.wav")
        let sequence = SystemLiveURLSequence([url])
        let permission = SystemAudioPermissionController(provider: SystemLivePermissionProvider())
        permission.refresh()
        let backend = SystemLiveCaptureBackend()
        let scheduler = SystemLiveScheduler()
        let controller = SystemAudioRecordingController(
            lifecycle: SystemAudioCaptureLifecycleController(permission: permission, backend: backend),
            backend: backend,
            transcriber: SystemLiveTranscriber(),
            scheduler: scheduler,
            outputURLFactory: { try sequence.next() }
        )

        try await controller.start()
        backend.emitPCM(Data([0x01, 0x02]))
        scheduler.fire()
        try await Task.sleep(for: .milliseconds(20))

        #expect(backend.stopCount == 1)
        #expect(controller.finalizedChunkURLs == [url])
        #expect(try Data(contentsOf: url).count == 46)
        if case .failed = controller.state {} else { Issue.record("Expected failed state") }
    }

    @Test
    func configuresRotatedChunksBeforeCaptureAndPreservesTerminalFailure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("system-live-failure-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = (1...3).map { directory.appendingPathComponent("chunk-\($0).wav") }
        let sequence = SystemLiveURLSequence(urls)
        let permission = SystemAudioPermissionController(provider: SystemLivePermissionProvider())
        permission.refresh()
        let backend = SystemLiveCaptureBackend()
        let scheduler = SystemLiveScheduler()
        let transcriber = SystemLiveTranscriber()
        let controller = SystemAudioRecordingController(
            lifecycle: SystemAudioCaptureLifecycleController(permission: permission, backend: backend),
            backend: backend,
            transcriber: transcriber,
            scheduler: scheduler,
            outputURLFactory: { try sequence.next() }
        )

        try await controller.start(modelName: "large-v3", language: "zh")
        backend.emitPCM(Data([0xff, 0x7f]))
        scheduler.fire()

        #expect(transcriber.submittedModelNames == ["large-v3"])
        #expect(transcriber.submittedLanguages == ["zh"])
        transcriber.failActiveJob()
        #expect(controller.submissionQueue.completedURLs.isEmpty)
        #expect(controller.submissionQueue.pendingURLs == [urls[0]])
        #expect(controller.submissionQueue.errorMessage?.contains("disk model failure") == true)

        backend.emitPCM(Data([0x00, 0x7f]))
        scheduler.fire()
        #expect(transcriber.submittedURLs == [urls[0]])
        #expect(controller.submissionQueue.pendingURLs == [urls[0], urls[1]])
        _ = try await controller.stop()
    }

    @Test
    func accumulatesCompletedSystemChunksOnceAndIgnoresUnrelatedAudio() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("system-live-results-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = (1...3).map { directory.appendingPathComponent("chunk-\($0).wav") }
        let sequence = SystemLiveURLSequence(urls)
        let permission = SystemAudioPermissionController(provider: SystemLivePermissionProvider())
        permission.refresh()
        let backend = SystemLiveCaptureBackend()
        let scheduler = SystemLiveScheduler()
        let controller = SystemAudioRecordingController(
            lifecycle: SystemAudioCaptureLifecycleController(permission: permission, backend: backend),
            backend: backend,
            transcriber: SystemLiveTranscriber(),
            scheduler: scheduler,
            outputURLFactory: { try sequence.next() }
        )

        try await controller.start()
        backend.emitPCM(Data([0xff, 0x7f]))
        scheduler.fire()
        backend.emitPCM(Data([0x00, 0x7f]))
        _ = try await controller.stop()

        #expect(controller.acceptCompletedChunk(
            urls[0], text: "第一段", segments: [], durationSeconds: nil
        ) == true)
        #expect(controller.transcriptText == "[00:00:00] 第一段")
        #expect(controller.transcriptSegments == [.init(start: 0, end: 15, text: "第一段")])
        #expect(controller.acceptCompletedChunk(urls[0], text: "重複") == false)
        #expect(controller.acceptCompletedChunk(urls[2], text: "無關") == false)

        #expect(controller.acceptCompletedChunk(
            urls[1], text: "第二段", segments: [.init(start: 0.5, end: 1.5, text: "第二段")],
            durationSeconds: 10
        ) == true)
        #expect(controller.transcriptText == "[00:00:00] 第一段\n[00:00:15] 第二段")
        #expect(controller.transcriptSegments.last == .init(start: 15.5, end: 16.5, text: "第二段"))
        let entry = TranscriptionHistoryEntry(
            audioPath: urls[0].path, model: "base", language: "zh",
            text: controller.transcriptText, segments: controller.transcriptSegments
        )
        let exported = try TranscriptionExportFormat.timecodedText.render(
            entry: entry, editedText: controller.transcriptText
        )
        #expect(exported.contains("[00:00:00] 第一段"))
        #expect(exported.contains("[00:00:15] 第二段"))
    }

    @Test
    func rotatesContinuousSystemCaptureAndDrainsFinalChunkInOrder() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("system-live-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = (1...3).map { directory.appendingPathComponent("chunk-\($0).wav") }
        let sequence = SystemLiveURLSequence(urls)
        let permission = SystemAudioPermissionController(
            provider: SystemLivePermissionProvider()
        )
        permission.refresh()
        let backend = SystemLiveCaptureBackend()
        let lifecycle = SystemAudioCaptureLifecycleController(permission: permission, backend: backend)
        let scheduler = SystemLiveScheduler()
        let transcriber = SystemLiveTranscriber()
        let controller = SystemAudioRecordingController(
            lifecycle: lifecycle,
            backend: backend,
            transcriber: transcriber,
            scheduler: scheduler,
            rotationInterval: 15,
            outputURLFactory: { try sequence.next() }
        )

        try await controller.start()
        backend.emitPCM(Data([0x01, 0x02]))
        scheduler.fire()
        backend.emitPCM(Data([0x03, 0x04]))

        #expect(controller.finalizedChunkURLs == [urls[0]])
        #expect(transcriber.submittedURLs == [urls[0]])

        _ = try await controller.stop()
        #expect(controller.finalizedChunkURLs == [urls[0], urls[1]])
        #expect(controller.submissionQueue.pendingURLs == [urls[1]])
        let sessionURL = try #require(controller.sessionFinalizedURL)
        #expect(sessionURL != urls[0])
        #expect(try Data(contentsOf: sessionURL).count == 48)

        transcriber.completeActiveJob()
        #expect(transcriber.submittedURLs == [urls[0], urls[1]])
        transcriber.completeActiveJob()
        #expect(controller.submissionQueue.pendingURLs.isEmpty)
        #expect(controller.submissionQueue.activeURL == nil)
        #expect(!FileManager.default.fileExists(atPath: urls[0].path))
        #expect(!FileManager.default.fileExists(atPath: urls[1].path))
        #expect(FileManager.default.fileExists(atPath: sessionURL.path))
    }
}
