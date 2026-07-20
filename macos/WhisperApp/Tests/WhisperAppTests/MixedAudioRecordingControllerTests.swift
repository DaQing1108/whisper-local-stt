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
private final class MixedTranscriber: AudioTranscribing {
    var state: WorkerState = .ready
    private(set) var receivedURL: URL?
    func transcribe(audioURL: URL, modelName: String, language: String?) throws -> String {
        receivedURL = audioURL
        return "mixed-job"
    }
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
    func mixesBothSourcesAndSubmitsOnlyAfterStop() async throws {
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
        #expect(transcriber.receivedURL == nil)

        let finalized = try await controller.stopAndTranscribe(modelName: "base")
        #expect(finalized == url)
        #expect(transcriber.receivedURL == url)
        #expect(mic.stopCount == 1)
        #expect(system.stopCount == 1)
        let bytes = try Data(contentsOf: url)
        #expect(bytes.count == 48)
        #expect(bytes[44] == 0xD0 && bytes[45] == 0x07)
        try? FileManager.default.removeItem(at: url)
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
            transcriber: nil
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
            transcriber: nil
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
            transcriber: nil
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
    func drainedTerminalErrorDiscardsSessionWithoutBlockingRestart() async throws {
        let mic = MixedMicrophoneBackend()
        let system = MixedSystemBackend()
        let controller = MixedAudioRecordingController(
            microphonePermission: MixedMicrophonePermission(granted: true),
            screenPermission: SystemAudioPermissionController(provider: MixedScreenPermission(granted: true)),
            microphoneBackend: mic,
            systemBackend: system,
            scheduler: MixedScheduler(),
            transcriber: nil
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
