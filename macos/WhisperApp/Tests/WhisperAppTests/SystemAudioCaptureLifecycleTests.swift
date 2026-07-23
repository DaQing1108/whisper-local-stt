import Foundation
import Testing
@testable import WhisperApp

private enum FakeSystemAudioCaptureError: Error {
    case startFailed
    case stopFailed
}

private struct LifecyclePermissionProvider: ScreenRecordingPermissionProviding {
    let granted: Bool

    func preflight() -> Bool { granted }
    func request() -> Bool { granted }
}

@MainActor
private final class FakeSystemAudioCaptureBackend: SystemAudioCaptureBackend {
    var startError: Error?
    var stopError: Error?
    var suspendStart = false
    var suspendStop = false
    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0
    private var errorHandler: (@MainActor @Sendable (Error) -> Void)?
    private var pcmHandler: (@Sendable (Data) -> Void)?
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var stopContinuations: [CheckedContinuation<Void, Never>] = []

    func start() async throws {
        startCallCount += 1
        if suspendStart {
            await withCheckedContinuation { continuation in
                startContinuation = continuation
            }
        }
        if let startError { throw startError }
    }

    func stop() async throws {
        stopCallCount += 1
        if suspendStop {
            await withCheckedContinuation { continuation in
                stopContinuations.append(continuation)
            }
        }
        if let stopError { throw stopError }
    }

    func setErrorHandler(_ handler: @escaping @MainActor @Sendable (Error) -> Void) {
        errorHandler = handler
    }

    func setPCMHandler(_ handler: @escaping @Sendable (Data) -> Void) {
        pcmHandler = handler
    }

    func emitPCM(_ data: Data) { pcmHandler?(data) }

    func resumeStart() {
        startContinuation?.resume()
        startContinuation = nil
    }

    func resumeStop() {
        let continuations = stopContinuations
        stopContinuations = []
        continuations.forEach { $0.resume() }
    }
}

@MainActor
private final class FakeSystemAudioTranscriber: LiveAudioTranscribing {
    var state: WorkerState = .ready
    private(set) var receivedURL: URL?

    func addTerminalObserver(_ observer: @escaping @MainActor @Sendable (String?, String) -> Void) -> UUID { UUID() }
    func addLostObserver(_ observer: @escaping @MainActor @Sendable (String) -> Void) -> UUID { UUID() }
    func addReadyObserver(_ observer: @escaping @MainActor @Sendable () -> Void) -> UUID { UUID() }
    func addUnavailableObserver(_ observer: @escaping @MainActor @Sendable (WorkerState) -> Void) -> UUID { UUID() }
    func removeObserver(_ id: UUID) {}
    func cancel() throws {}

    func transcribe(audioURL: URL, modelName: String, language: String?) throws -> String {
        receivedURL = audioURL
        return "system-audio-job"
    }
}

@MainActor
struct SystemAudioCaptureLifecycleTests {
    @Test
    func deniedPermissionDoesNotStartTheBackend() async {
        let permission = SystemAudioPermissionController(
            provider: LifecyclePermissionProvider(granted: false)
        )
        permission.refresh()
        let backend = FakeSystemAudioCaptureBackend()
        let controller = SystemAudioCaptureLifecycleController(
            permission: permission,
            backend: backend
        )

        await controller.start()

        #expect(controller.state == .failed("Screen Recording access is required for system audio"))
        #expect(backend.startCallCount == 0)
    }

    @Test
    func grantedPermissionStartsThenStopsTheBackend() async {
        let permission = SystemAudioPermissionController(
            provider: LifecyclePermissionProvider(granted: true)
        )
        permission.refresh()
        let backend = FakeSystemAudioCaptureBackend()
        let controller = SystemAudioCaptureLifecycleController(
            permission: permission,
            backend: backend
        )

        await controller.start()
        #expect(controller.state == .capturing)
        #expect(backend.startCallCount == 1)

        await controller.stop()
        #expect(controller.state == .idle)
        #expect(backend.stopCallCount == 1)
    }

    @Test
    func backendStartFailureIsExposedWithoutEnteringCaptureState() async {
        let permission = SystemAudioPermissionController(
            provider: LifecyclePermissionProvider(granted: true)
        )
        permission.refresh()
        let backend = FakeSystemAudioCaptureBackend()
        backend.startError = FakeSystemAudioCaptureError.startFailed
        let controller = SystemAudioCaptureLifecycleController(
            permission: permission,
            backend: backend
        )

        await controller.start()

        #expect(controller.state == .failed(FakeSystemAudioCaptureError.startFailed.localizedDescription))
        #expect(backend.startCallCount == 1)
        #expect(backend.stopCallCount == 0)
    }

    @Test
    func stopFailurePreventsRestartUntilACleanupRetrySucceeds() async {
        let permission = SystemAudioPermissionController(
            provider: LifecyclePermissionProvider(granted: true)
        )
        permission.refresh()
        let backend = FakeSystemAudioCaptureBackend()
        let controller = SystemAudioCaptureLifecycleController(
            permission: permission,
            backend: backend
        )
        await controller.start()
        backend.stopError = FakeSystemAudioCaptureError.stopFailed

        await controller.stop()
        #expect(controller.state == .failed(FakeSystemAudioCaptureError.stopFailed.localizedDescription))

        await controller.start()
        #expect(backend.startCallCount == 1)

        backend.stopError = nil
        await controller.stop()
        #expect(backend.stopCallCount == 2)
        #expect(controller.state == .idle)
    }

    @Test
    func concurrentStartIsSingleFlightAndStopDuringStartIsHonored() async {
        let permission = SystemAudioPermissionController(
            provider: LifecyclePermissionProvider(granted: true)
        )
        permission.refresh()
        let backend = FakeSystemAudioCaptureBackend()
        backend.suspendStart = true
        let controller = SystemAudioCaptureLifecycleController(
            permission: permission,
            backend: backend
        )

        let startTask = Task { await controller.start() }
        await Task.yield()
        #expect(controller.state == .starting)
        #expect(backend.startCallCount == 1)

        await controller.start()
        #expect(backend.startCallCount == 1)

        await controller.stop()
        #expect(controller.state == .stopping)
        #expect(backend.stopCallCount == 0)

        backend.resumeStart()
        await startTask.value

        #expect(backend.stopCallCount == 1)
        #expect(controller.state == .idle)
    }

    @Test
    func concurrentStopIsSingleFlight() async {
        let permission = SystemAudioPermissionController(
            provider: LifecyclePermissionProvider(granted: true)
        )
        permission.refresh()
        let backend = FakeSystemAudioCaptureBackend()
        let controller = SystemAudioCaptureLifecycleController(
            permission: permission,
            backend: backend
        )
        await controller.start()
        backend.suspendStop = true

        Task { await controller.stop() }
        await Task.yield()
        #expect(controller.state == .stopping)
        #expect(backend.stopCallCount == 1)

        Task { await controller.stop() }
        await Task.yield()
        #expect(backend.stopCallCount == 1)

        backend.resumeStop()
        await Task.yield()
        #expect(controller.state == .idle)
    }

    @Test
    func runtimeCaptureErrorMovesTheControllerToFailedState() async {
        let permission = SystemAudioPermissionController(provider: LifecyclePermissionProvider(granted: true))
        permission.refresh()
        let controller = SystemAudioCaptureLifecycleController(
            permission: permission,
            backend: FakeSystemAudioCaptureBackend()
        )

        controller.handleRuntimeError(SystemAudioCaptureError.streamStopped("device lost"))

        #expect(controller.state == .failed("System audio capture stopped: device lost"))
    }

}
