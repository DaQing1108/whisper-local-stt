import Foundation
import Observation

@MainActor
protocol AudioTranscribing: AnyObject {
    var state: WorkerState { get }
    @discardableResult
    func transcribe(audioURL: URL, modelName: String, language: String?) throws -> String
    @discardableResult
    func transcribe(
        audioURL: URL, modelName: String, language: String?, domain: String, extraTerms: String
    ) throws -> String
}

extension AudioTranscribing {
    @discardableResult
    func transcribe(
        audioURL: URL, modelName: String, language: String?, domain: String, extraTerms: String
    ) throws -> String {
        try transcribe(audioURL: audioURL, modelName: modelName, language: language)
    }
}

extension WorkerSupervisor: AudioTranscribing {}

enum StandardRecordingError: Error, Equatable {
    case workerNotReady
}

@MainActor
@Observable
final class StandardRecordingController {
    private(set) var errorMessage: String?
    private(set) var isStarting = false

    let microphone: MicrophoneCaptureService
    private let transcriber: any AudioTranscribing
    private let outputURLFactory: @MainActor @Sendable () throws -> URL

    var state: RecordingState { microphone.state }
    var finalizedAudioURL: URL? { microphone.lastFinalizedURL }

    init(
        microphone: MicrophoneCaptureService,
        transcriber: any AudioTranscribing,
        outputURLFactory: @escaping @MainActor @Sendable () throws -> URL = {
            try StandardRecordingController.makeOutputURL()
        }
    ) {
        self.microphone = microphone
        self.transcriber = transcriber
        self.outputURLFactory = outputURLFactory
    }

    func start() async {
        guard !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        if state != .idle { microphone.reset() }
        errorMessage = nil
        guard await microphone.resolvePermission() else {
            errorMessage = recordingFailureMessage
            return
        }
        do {
            try microphone.start(outputURL: outputURLFactory())
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func stopAndTranscribe(
        modelName: String, language: String? = nil, domain: String = "general", extraTerms: String = ""
    ) throws -> URL {
        do {
            let url = try microphone.stop()
            guard transcriber.state == .ready else {
                errorMessage = "Recording saved; Python Worker is not ready"
                throw StandardRecordingError.workerNotReady
            }
            _ = try transcriber.transcribe(
                audioURL: url, modelName: modelName, language: language,
                domain: domain, extraTerms: extraTerms
            )
            errorMessage = nil
            return url
        } catch {
            if errorMessage == nil { errorMessage = error.localizedDescription }
            throw error
        }
    }

    private var recordingFailureMessage: String {
        if case .failed(let message) = state { return message }
        return "Microphone permission was not granted"
    }

    private static func makeOutputURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base
            .appendingPathComponent("WhisperSwiftUI", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        let filename = "recording-\(formatter.string(from: Date()))-\(UUID().uuidString).wav"
        return directory.appendingPathComponent(filename)
    }
}
