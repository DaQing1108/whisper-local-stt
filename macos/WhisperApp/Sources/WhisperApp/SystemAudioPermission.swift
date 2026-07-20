import CoreGraphics
import Observation

enum ScreenRecordingPermissionStatus: Equatable, Sendable {
    case unknown
    case granted
    case denied
}

protocol ScreenRecordingPermissionProviding: Sendable {
    func preflight() -> Bool
    func request() -> Bool
}

struct SystemScreenRecordingPermissionProvider: ScreenRecordingPermissionProviding {
    func preflight() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}

@MainActor
@Observable
final class SystemAudioPermissionController {
    private let provider: any ScreenRecordingPermissionProviding
    private(set) var status: ScreenRecordingPermissionStatus = .unknown

    init(provider: any ScreenRecordingPermissionProviding = SystemScreenRecordingPermissionProvider()) {
        self.provider = provider
    }

    var statusMessage: String {
        switch status {
        case .unknown:
            "Screen Recording access has not been checked"
        case .granted:
            "Screen Recording access granted"
        case .denied:
            "Screen Recording access is required for system audio"
        }
    }

    func refresh() {
        status = provider.preflight() ? .granted : .denied
    }

    @discardableResult
    func requestAccess() -> ScreenRecordingPermissionStatus {
        status = provider.request() ? .granted : .denied
        return status
    }
}
