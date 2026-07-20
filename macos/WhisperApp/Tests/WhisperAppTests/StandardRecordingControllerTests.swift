import Foundation
import Testing
@testable import WhisperApp

private struct ControllerPermissionProvider: MicrophonePermissionProviding {
    let granted: Bool
    func status() -> MicrophonePermission { granted ? .granted : .denied }
    func requestAccess() async -> Bool { granted }
}

private final class SuspendedPermissionProvider: MicrophonePermissionProviding, @unchecked Sendable {
    private let continuationLock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    func status() -> MicrophonePermission { .notDetermined }
    func requestAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            continuationLock.lock()
            self.continuation = continuation
            continuationLock.unlock()
        }
    }
    func resolve(_ granted: Bool) {
        continuationLock.lock()
        let continuation = self.continuation
        self.continuation = nil
        continuationLock.unlock()
        continuation?.resume(returning: granted)
    }
    var isWaiting: Bool {
        continuationLock.lock()
        defer { continuationLock.unlock() }
        return continuation != nil
    }
}

private final class ControllerCaptureBackend: AudioCaptureBackend, @unchecked Sendable {
    private var onPCM: (@Sendable (Data) -> Void)?
    private var onError: (@Sendable (Error) -> Void)?

    func start(
        onPCM: @escaping @Sendable (Data) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) throws {
        self.onPCM = onPCM
        self.onError = onError
    }

    func stop() throws {}
    func emit(_ data: Data) { onPCM?(data) }
    func fail(_ error: Error) { onError?(error) }
}

@MainActor
private final class FakeTranscriber: AudioTranscribing {
    var state: WorkerState = .ready
    private(set) var audioURL: URL?
    private(set) var modelName: String?

    func transcribe(audioURL: URL, modelName: String, language: String?) throws -> String {
        self.audioURL = audioURL
        self.modelName = modelName
        return "request-1"
    }
}

@MainActor
struct StandardRecordingControllerTests {
    @Test
    func recordsFinalizesAndHandsFileToWorker() async throws {
        let backend = ControllerCaptureBackend()
        let microphone = MicrophoneCaptureService(
            permissionProvider: ControllerPermissionProvider(granted: true),
            backend: backend
        )
        let transcriber = FakeTranscriber()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("standard-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = StandardRecordingController(
            microphone: microphone,
            transcriber: transcriber,
            outputURLFactory: { url }
        )

        await controller.start()
        backend.emit(Data([0x01, 0x02, 0x03, 0x04]))
        let finalized = try controller.stopAndTranscribe(modelName: "base", language: "zh")

        #expect(finalized == url)
        #expect(transcriber.audioURL == url)
        #expect(transcriber.modelName == "base")
        #expect(try Data(contentsOf: url).count == 48)
    }

    @Test
    func preservesFinalizedFileWhenWorkerIsNotReady() async throws {
        let microphone = MicrophoneCaptureService(
            permissionProvider: ControllerPermissionProvider(granted: true),
            backend: ControllerCaptureBackend()
        )
        let transcriber = FakeTranscriber()
        transcriber.state = .stopped
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("not-ready-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = StandardRecordingController(
            microphone: microphone,
            transcriber: transcriber,
            outputURLFactory: { url }
        )

        await controller.start()
        #expect(throws: StandardRecordingError.workerNotReady) {
            try controller.stopAndTranscribe(modelName: "base")
        }

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(controller.finalizedAudioURL == url)
    }

    @Test
    func ignoresSecondStartWhilePermissionRequestIsPending() async throws {
        let permission = SuspendedPermissionProvider()
        let backend = ControllerCaptureBackend()
        let microphone = MicrophoneCaptureService(permissionProvider: permission, backend: backend)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pending-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = StandardRecordingController(
            microphone: microphone,
            transcriber: FakeTranscriber(),
            outputURLFactory: { url }
        )

        let firstStart = Task { await controller.start() }
        while microphone.state != .requestingPermission || !permission.isWaiting { await Task.yield() }
        await controller.start()
        #expect(controller.isStarting)
        #expect(microphone.state == .requestingPermission)
        permission.resolve(true)
        await firstStart.value

        if case .recording = microphone.state {} else { Issue.record("Expected one active recording") }
    }

    @Test
    func exposesRecoveryURLAfterRuntimeCaptureFailure() async throws {
        let backend = ControllerCaptureBackend()
        let microphone = MicrophoneCaptureService(
            permissionProvider: ControllerPermissionProvider(granted: true),
            backend: backend
        )
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = StandardRecordingController(
            microphone: microphone,
            transcriber: FakeTranscriber(),
            outputURLFactory: { url }
        )

        await controller.start()
        backend.fail(AudioCaptureError.conversionFailed)
        await Task.yield()

        #expect(controller.finalizedAudioURL == url)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
