@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import WhisperApp

private struct FakePermissionProvider: MicrophonePermissionProviding {
    let current: MicrophonePermission
    let requestedResult: Bool

    func status() -> MicrophonePermission { current }
    func requestAccess() async -> Bool { requestedResult }
}

private final class FakeCaptureBackend: AudioCaptureBackend, @unchecked Sendable {
    var startError: Error?
    var stopError: Error?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var onPCM: (@Sendable (Data) -> Void)?
    private var onError: (@Sendable (Error) -> Void)?

    func start(
        onPCM: @escaping @Sendable (Data) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) throws {
        startCount += 1
        if let startError { throw startError }
        self.onPCM = onPCM
        self.onError = onError
    }

    func stop() throws {
        stopCount += 1
        if let stopError { throw stopError }
    }

    func emit(_ data: Data) { onPCM?(data) }
    func fail(_ error: Error) { onError?(error) }
}

private final class BlockingCaptureBackend: AudioCaptureBackend, @unchecked Sendable {
    private let group = DispatchGroup()
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private var onPCM: (@Sendable (Data) -> Void)?

    func start(
        onPCM: @escaping @Sendable (Data) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) throws {
        self.onPCM = onPCM
    }

    func emitBlocked(_ data: Data) {
        group.enter()
        DispatchQueue.global().async { [self] in
            entered.signal()
            release.wait()
            onPCM?(data)
            group.leave()
        }
        entered.wait()
    }

    func unblock() { release.signal() }
    func stop() throws { group.wait() }
}

struct MicrophoneCaptureServiceTests {
    @Test
    func computesAccessibleNormalizedPCMLevel() {
        var data = Data()
        for value: Int16 in [0, Int16.max, Int16.min + 1] {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        let level = MicrophoneCaptureService.normalizedLevel(forPCM16: data)
        #expect(level > 0.8)
        #expect(level <= 1)
        #expect(MicrophoneCaptureService.normalizedLevel(forPCM16: Data()) == 0)
    }
    @Test
    func converts48kHzFloatMonoTo16kHzInt16PCM() throws {
        let inputFormat = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
        let outputFormat = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ))
        let input = try #require(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 480))
        input.frameLength = 480
        let samples = try #require(input.floatChannelData?[0])
        for index in 0..<480 { samples[index] = index.isMultiple(of: 2) ? 0.5 : -0.5 }
        let converter = try #require(AVAudioConverter(from: inputFormat, to: outputFormat))

        let converted = try AVAudioEngineCaptureBackend.convert(input, with: converter, to: outputFormat)
        let data = try #require(converted)

        // AVAudioConverter priming can trim a few frames from the first buffer.
        #expect((300...322).contains(data.count))
        #expect(data.count.isMultiple(of: 2))
        #expect(data.contains { $0 != 0 })
    }

    @Test @MainActor
    func mapsAlreadyGrantedPermissionToReadyWithoutPrompting() async {
        let service = MicrophoneCaptureService(
            permissionProvider: FakePermissionProvider(current: .granted, requestedResult: false),
            backend: FakeCaptureBackend()
        )

        #expect(await service.resolvePermission())
        #expect(service.state == .ready)
    }

    @Test @MainActor
    func mapsDeniedAndRestrictedPermissionsToFailures() async {
        let denied = MicrophoneCaptureService(
            permissionProvider: FakePermissionProvider(current: .denied, requestedResult: true),
            backend: FakeCaptureBackend()
        )
        #expect(await !denied.resolvePermission())
        #expect(denied.state == .failed("Microphone permission denied"))

        let restricted = MicrophoneCaptureService(
            permissionProvider: FakePermissionProvider(current: .restricted, requestedResult: true),
            backend: FakeCaptureBackend()
        )
        #expect(await !restricted.resolvePermission())
        #expect(restricted.state == .failed("Microphone permission restricted"))
    }

    @Test @MainActor
    func requestsUndeterminedPermissionAndMapsTheResult() async {
        let service = MicrophoneCaptureService(
            permissionProvider: FakePermissionProvider(current: .notDetermined, requestedResult: true),
            backend: FakeCaptureBackend()
        )

        #expect(await service.resolvePermission())
        #expect(service.state == .ready)
    }

    @Test @MainActor
    func startsWritesPCMStopsAndFinalizesWAV() async throws {
        let backend = FakeCaptureBackend()
        let service = MicrophoneCaptureService(
            permissionProvider: FakePermissionProvider(current: .granted, requestedResult: false),
            backend: backend
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("microphone-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(await service.resolvePermission())
        try service.start(outputURL: url, at: Date(timeIntervalSince1970: 123))
        backend.emit(Data([0x01, 0x02, 0x03, 0x04]))
        await Task.yield()
        let finalized = try service.stop()

        #expect(finalized == url)
        #expect(service.state == .recorded(url))
        #expect(backend.startCount == 1)
        #expect(backend.stopCount == 1)
        #expect(try Data(contentsOf: url).count == 48)
    }

    @Test @MainActor
    func mapsBackendStartAndRuntimeErrorsToFailedState() async throws {
        let startBackend = FakeCaptureBackend()
        startBackend.startError = AudioCaptureError.invalidInputFormat
        let startService = MicrophoneCaptureService(
            permissionProvider: FakePermissionProvider(current: .granted, requestedResult: false),
            backend: startBackend
        )
        let startURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: startURL) }
        #expect(await startService.resolvePermission())
        #expect(throws: AudioCaptureError.invalidInputFormat) {
            try startService.start(outputURL: startURL)
        }
        if case .failed = startService.state {} else { Issue.record("Expected failed state") }

        let runtimeBackend = FakeCaptureBackend()
        let runtimeService = MicrophoneCaptureService(
            permissionProvider: FakePermissionProvider(current: .granted, requestedResult: false),
            backend: runtimeBackend
        )
        let runtimeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: runtimeURL) }
        #expect(await runtimeService.resolvePermission())
        try runtimeService.start(outputURL: runtimeURL)
        runtimeBackend.fail(AudioCaptureError.conversionFailed)
        await Task.yield()
        if case .failed = runtimeService.state {} else { Issue.record("Expected failed state") }
        #expect(runtimeBackend.stopCount == 1)
    }

    @Test @MainActor
    func finalizesRecoveryWAVWhenBackendStopFails() async throws {
        let backend = FakeCaptureBackend()
        backend.stopError = AudioCaptureError.conversionFailed
        let service = MicrophoneCaptureService(
            permissionProvider: FakePermissionProvider(current: .granted, requestedResult: false),
            backend: backend
        )
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stop-error-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(await service.resolvePermission())
        try service.start(outputURL: url)
        backend.emit(Data([0x01, 0x02]))
        #expect(throws: AudioCaptureError.conversionFailed) { try service.stop() }

        #expect(try Data(contentsOf: url).count == 46)
        if case .failed = service.state {} else { Issue.record("Expected failed state") }
    }

    @Test @MainActor
    func resetSupportsASecondRecordingCycle() async throws {
        let backend = FakeCaptureBackend()
        let service = MicrophoneCaptureService(
            permissionProvider: FakePermissionProvider(current: .granted, requestedResult: false),
            backend: backend
        )
        let firstURL = FileManager.default.temporaryDirectory.appendingPathComponent("first-\(UUID()).wav")
        let secondURL = FileManager.default.temporaryDirectory.appendingPathComponent("second-\(UUID()).wav")
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }

        #expect(await service.resolvePermission())
        try service.start(outputURL: firstURL)
        _ = try service.stop()
        service.reset()
        #expect(service.state == .idle)
        #expect(await service.resolvePermission())
        try service.start(outputURL: secondURL)
        _ = try service.stop()

        #expect(service.state == .recorded(secondURL))
        #expect(backend.startCount == 2)
        #expect(backend.stopCount == 2)
    }

    @Test @MainActor
    func ignoresLateErrorFromFinalizedSession() async throws {
        let backend = FakeCaptureBackend()
        let service = MicrophoneCaptureService(
            permissionProvider: FakePermissionProvider(current: .granted, requestedResult: false),
            backend: backend
        )
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("late-error-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(await service.resolvePermission())
        try service.start(outputURL: url)
        _ = try service.stop()
        backend.fail(AudioCaptureError.conversionFailed)
        await Task.yield()

        #expect(service.state == .recorded(url))
    }

    @Test @MainActor
    func stopDrainsPCMCallbackAcceptedByBackend() async throws {
        let backend = BlockingCaptureBackend()
        let service = MicrophoneCaptureService(
            permissionProvider: FakePermissionProvider(current: .granted, requestedResult: false),
            backend: backend
        )
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("drain-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(await service.resolvePermission())
        try service.start(outputURL: url)
        backend.emitBlocked(Data([0x01, 0x02, 0x03, 0x04]))
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.01) { backend.unblock() }
        _ = try service.stop()

        #expect(try Data(contentsOf: url).count == 48)
    }
}
