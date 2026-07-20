import Foundation
import Observation

enum SystemAudioCaptureState: Equatable, Sendable {
    case idle
    case starting
    case capturing
    case stopping
    case failed(String)
}

@MainActor
protocol SystemAudioCaptureBackend: AnyObject {
    func start() async throws
    func stop() async throws
    func setErrorHandler(_ handler: @escaping @MainActor @Sendable (Error) -> Void)
    func setPCMHandler(_ handler: @escaping @Sendable (Data) -> Void)
}

@MainActor
@Observable
final class SystemAudioCaptureLifecycleController {
    private(set) var state: SystemAudioCaptureState = .idle
    private(set) var terminalError: Error?

    private let permission: SystemAudioPermissionController
    private let backend: any SystemAudioCaptureBackend
    private var backendIsActive = false
    private var isStarting = false
    private var isStopping = false
    private var stopRequestedDuringStart = false

    var hasActiveCapture: Bool { backendIsActive || isStarting || isStopping }

    init(
        permission: SystemAudioPermissionController,
        backend: any SystemAudioCaptureBackend
    ) {
        self.permission = permission
        self.backend = backend
        backend.setErrorHandler { [weak self] error in
            self?.handleRuntimeError(error)
        }
    }

    func start() async {
        guard !backendIsActive, !isStarting else { return }
        guard permission.status == .granted else {
            state = .failed("Screen Recording access is required for system audio")
            return
        }
        terminalError = nil
        isStarting = true
        stopRequestedDuringStart = false
        state = .starting
        do {
            try await backend.start()
            backendIsActive = true
            isStarting = false
            if stopRequestedDuringStart {
                stopRequestedDuringStart = false
                await stop()
            } else {
                state = .capturing
            }
        } catch {
            isStarting = false
            stopRequestedDuringStart = false
            state = .failed(error.localizedDescription)
        }
    }

    func stop() async {
        if isStarting {
            stopRequestedDuringStart = true
            state = .stopping
            return
        }
        guard backendIsActive, !isStopping else { return }
        isStopping = true
        defer { isStopping = false }
        state = .stopping
        do {
            try await backend.stop()
            backendIsActive = false
            state = .idle
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func handleRuntimeError(_ error: Error) {
        terminalError = error
        state = .failed(error.localizedDescription)
    }
}
