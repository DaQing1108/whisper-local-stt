import Foundation
import Testing
@testable import WhisperApp

private final class FakeScreenRecordingPermissionProvider: ScreenRecordingPermissionProviding, @unchecked Sendable {
    let preflightResult: Bool
    let requestResult: Bool
    private let lock = NSLock()
    private var storedPreflightCallCount = 0
    private var storedRequestCallCount = 0

    init(preflightResult: Bool, requestResult: Bool) {
        self.preflightResult = preflightResult
        self.requestResult = requestResult
    }

    var preflightCallCount: Int {
        lock.withLock { storedPreflightCallCount }
    }

    var requestCallCount: Int {
        lock.withLock { storedRequestCallCount }
    }

    func preflight() -> Bool {
        lock.withLock { storedPreflightCallCount += 1 }
        return preflightResult
    }

    func request() -> Bool {
        lock.withLock { storedRequestCallCount += 1 }
        return requestResult
    }
}

@MainActor
struct SystemAudioPermissionTests {
    @Test
    func refreshMapsScreenRecordingPermissionWithoutRequestingAccess() {
        let allowedProvider = FakeScreenRecordingPermissionProvider(
            preflightResult: true,
            requestResult: false
        )
        let allowed = SystemAudioPermissionController(provider: allowedProvider)
        allowed.refresh()
        #expect(allowed.status == .granted)
        #expect(allowedProvider.preflightCallCount == 1)
        #expect(allowedProvider.requestCallCount == 0)

        let deniedProvider = FakeScreenRecordingPermissionProvider(
            preflightResult: false,
            requestResult: true
        )
        let denied = SystemAudioPermissionController(provider: deniedProvider)
        denied.refresh()
        #expect(denied.status == .denied)
        #expect(deniedProvider.preflightCallCount == 1)
        #expect(deniedProvider.requestCallCount == 0)
    }

    @Test
    func explicitAccessRequestMapsTheProviderResult() {
        let provider = FakeScreenRecordingPermissionProvider(
            preflightResult: false,
            requestResult: true
        )
        let controller = SystemAudioPermissionController(provider: provider)

        let status = controller.requestAccess()

        #expect(status == .granted)
        #expect(controller.status == .granted)
        #expect(provider.preflightCallCount == 0)
        #expect(provider.requestCallCount == 1)
    }

    @Test
    func statusMessageExplainsWhetherAnExplicitRequestIsNeeded() {
        let controller = SystemAudioPermissionController(
            provider: FakeScreenRecordingPermissionProvider(
                preflightResult: false,
                requestResult: false
            )
        )

        #expect(controller.statusMessage == "Screen Recording access has not been checked")
        controller.refresh()
        #expect(controller.statusMessage == "Screen Recording access is required for system audio")
    }
}
