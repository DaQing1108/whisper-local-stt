import Foundation
import Observation

enum WorkerState: Equatable, Sendable {
    case stopped
    case starting
    case restarting(Int)
    case ready
    case failed(String)
}

enum WorkerSupervisorError: Error, Equatable {
    case transcriptionAlreadyActive
    case modelOperationActive
    case diarizationOperationActive
}

struct WorkerLaunchConfiguration: Sendable {
    let executableURL: URL
    let arguments: [String]
    let workingDirectory: URL

    static func discover(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        bundledResourceURL: URL? = Bundle.main.resourceURL
    ) throws -> WorkerLaunchConfiguration {
        if let bundledPath = environment["WHISPER_WORKER_EXECUTABLE"] {
            let executable = URL(fileURLWithPath: bundledPath)
            guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                throw CocoaError(.fileNoSuchFile)
            }
            return WorkerLaunchConfiguration(
                executableURL: executable,
                arguments: [],
                workingDirectory: executable.deletingLastPathComponent()
            )
        }
        if let bundledWorker = bundledResourceURL?
            .appendingPathComponent("WhisperWorker")
            .appendingPathComponent("WhisperWorker"),
           FileManager.default.isExecutableFile(atPath: bundledWorker.path) {
            return WorkerLaunchConfiguration(
                executableURL: bundledWorker,
                arguments: [],
                workingDirectory: bundledWorker.deletingLastPathComponent()
            )
        }
        let start = environment["WHISPER_REPO_ROOT"].map { URL(fileURLWithPath: $0) } ?? currentDirectory
        var candidate = start.standardizedFileURL
        while candidate.path != "/" {
            let worker = candidate.appendingPathComponent("worker_entrypoint.py")
            if FileManager.default.fileExists(atPath: worker.path) {
                let python = environment["WHISPER_PYTHON"].map { URL(fileURLWithPath: $0) }
                    ?? URL(fileURLWithPath: "/usr/bin/python3")
                return WorkerLaunchConfiguration(
                    executableURL: python,
                    arguments: ["-u", worker.path],
                    workingDirectory: candidate
                )
            }
            candidate.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}

@MainActor
@Observable
final class WorkerSupervisor {
    struct CompletedTranscription: Sendable {
        let audioURL: URL
        let modelName: String
        let language: String?
        let text: String
        let segments: [TranscriptionSegment]
        let durationSeconds: Double?
        let domain: String
        let extraTerms: String
    }
    private(set) var state: WorkerState = .stopped
    private(set) var lastEvent: WorkerEvent?
    private(set) var activeJobID: String?
    private(set) var activeRequestID: String?
    private(set) var progress: Double = 0
    private(set) var partialText = ""
    private(set) var resultText = ""
    private(set) var jobStatus = "Idle"
    private(set) var diagnostics = ""
    private(set) var restartCount = 0
    private(set) var diarizationAvailable = false
    private(set) var diarizationCapabilityMessage = "Diarization capability not checked"
    private(set) var latestCompletedTranscription: CompletedTranscription?
    private(set) var completionRevision = 0
    private(set) var unsuccessfulTerminalRevision = 0
    private(set) var modelReadiness = "unknown"
    private(set) var modelReadinessMessage = "Model status not checked"
    private(set) var modelOperationInProgress = false
    private(set) var diarizationStatus = "unknown"
    private(set) var diarizationOperationInProgress = false
    private(set) var diarizedSegments: [TranscriptionSegment] = []
    private(set) var diarizationFailureMessage: String?
    private(set) var llmPunctuationEnabled = false
    /// Injectable so tests don't touch the real Keychain; defaults to the real credential store.
    var llmCredentialLoader: (MeetingSummaryProvider) -> String? = {
        try? LLMCredentialStore(provider: $0).load()
    }
    var jobTerminalHandler: (@MainActor @Sendable (String?) -> Void)?
    var jobLostHandler: (@MainActor @Sendable (String) -> Void)?
    var workerReadyHandler: (@MainActor @Sendable () -> Void)?
    var workerUnavailableHandler: (@MainActor @Sendable (WorkerState) -> Void)?
    var transcriptionCompletedHandler: (@MainActor @Sendable (CompletedTranscription) -> Void)?
    private var terminalObservers: [UUID: @MainActor @Sendable (String?, String) -> Void] = [:]
    private var lostObservers: [UUID: @MainActor @Sendable (String) -> Void] = [:]
    private var readyObservers: [UUID: @MainActor @Sendable () -> Void] = [:]
    private var unavailableObservers: [UUID: @MainActor @Sendable (WorkerState) -> Void] = [:]

    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errorOutput: FileHandle?
    private var bufferedOutput = Data()
    private var launchConfiguration: WorkerLaunchConfiguration?
    private var isStopping = false
    private let maximumRestartAttempts = 2
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private struct ActiveTranscriptionContext {
        let requestID: String
        let audioURL: URL
        let modelName: String
        let language: String?
        let domain: String
        let extraTerms: String
    }
    private var activeTranscriptionContext: ActiveTranscriptionContext?
    private var modelRequestID: String?
    private var diarizationRequestID: String?

    func start(pythonURL: URL, workerURL: URL, workingDirectory: URL) throws {
        try start(configuration: WorkerLaunchConfiguration(
            executableURL: pythonURL,
            arguments: ["-u", workerURL.path],
            workingDirectory: workingDirectory
        ))
    }

    func start(configuration: WorkerLaunchConfiguration) throws {
        guard process == nil else { return }
        state = .starting
        restartCount = 0
        diagnostics = ""
        launchConfiguration = configuration
        try launch(configuration, isRestart: false)
    }

    private func launch(_ configuration: WorkerLaunchConfiguration, isRestart: Bool) throws {
        isStopping = false

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = configuration.executableURL
        process.arguments = configuration.arguments
        process.currentDirectoryURL = configuration.workingDirectory
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Process.environment REPLACES the inherited environment when set at all, so start
        // from the current environment and only layer keys on top — never send them via the
        // JSONL payload or any log-observable path.
        // Only OpenAI/Anthropic have Keychain storage today (MeetingSummaryProvider has no
        // .gemini case); the Worker also accepts GEMINI_API_KEY but there's no way for a user
        // to configure one in this app yet, so it's intentionally not forwarded here.
        var childEnvironment = ProcessInfo.processInfo.environment
        var punctuationEnabled = false
        if let anthropicKey = llmCredentialLoader(.anthropic), !anthropicKey.isEmpty {
            childEnvironment["ANTHROPIC_API_KEY"] = anthropicKey
            punctuationEnabled = true
        }
        if let openAIKey = llmCredentialLoader(.openAI), !openAIKey.isEmpty {
            childEnvironment["OPENAI_API_KEY"] = openAIKey
            punctuationEnabled = true
        }
        process.environment = childEnvironment
        llmPunctuationEnabled = punctuationEnabled

        let output = stdoutPipe.fileHandleForReading
        let errorOutput = stderrPipe.fileHandleForReading
        output.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in self?.consume(data) }
        }
        errorOutput.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in self?.consumeDiagnostics(data) }
        }
        process.terminationHandler = { [weak self] terminatedProcess in
            Task { @MainActor [weak self] in
                self?.didTerminate(terminatedProcess, status: terminatedProcess.terminationStatus)
            }
        }

        do {
            try process.run()
            self.process = process
            input = stdinPipe.fileHandleForWriting
            self.output = output
            self.errorOutput = errorOutput
            if isRestart { state = .restarting(restartCount) }
        } catch {
            output.readabilityHandler = nil
            errorOutput.readabilityHandler = nil
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    @discardableResult
    func ping() throws -> String {
        let requestID = UUID().uuidString
        try send(WorkerCommand(requestID: requestID, command: "ping", payload: [:]))
        return requestID
    }

    @discardableResult
    func requestCapabilities() throws -> String {
        let requestID = UUID().uuidString
        try send(WorkerCommand(requestID: requestID, command: "capabilities", payload: [:]))
        return requestID
    }

    @discardableResult
    func requestModelStatus(modelName: String) throws -> String {
        let requestID = UUID().uuidString
        modelRequestID = requestID
        modelOperationInProgress = true
        do {
            try send(WorkerCommand(
                requestID: requestID, command: "model_status",
                payload: ["model_name": .string(modelName)]
            ))
        } catch {
            modelRequestID = nil
            modelOperationInProgress = false
            throw error
        }
        return requestID
    }

    @discardableResult
    func warmupModel(modelName: String) throws -> String {
        guard activeRequestID == nil else { throw WorkerSupervisorError.transcriptionAlreadyActive }
        let requestID = UUID().uuidString
        modelRequestID = requestID
        modelOperationInProgress = true
        modelReadiness = "loading"
        modelReadinessMessage = "Loading \(modelName)…"
        do {
            try send(WorkerCommand(
                requestID: requestID, command: "warmup_model",
                payload: ["model_name": .string(modelName)]
            ))
        } catch {
            modelRequestID = nil
            modelOperationInProgress = false
            modelReadiness = "failed"
            modelReadinessMessage = error.localizedDescription
            throw error
        }
        return requestID
    }

    @discardableResult
    func diarizationWarmup() throws -> String {
        guard activeRequestID == nil else { throw WorkerSupervisorError.transcriptionAlreadyActive }
        guard !diarizationOperationInProgress else { throw WorkerSupervisorError.diarizationOperationActive }
        let requestID = UUID().uuidString
        diarizationRequestID = requestID
        diarizationOperationInProgress = true
        diarizationStatus = "loading"
        do {
            try send(WorkerCommand(requestID: requestID, command: "diarization_warmup", payload: [:]))
        } catch {
            diarizationRequestID = nil
            diarizationOperationInProgress = false
            diarizationStatus = "failed"
            throw error
        }
        return requestID
    }

    @discardableResult
    func diarize(audioPath: String, segments: [TranscriptionSegment]) throws -> String {
        guard activeRequestID == nil else { throw WorkerSupervisorError.transcriptionAlreadyActive }
        guard !diarizationOperationInProgress else { throw WorkerSupervisorError.diarizationOperationActive }
        let requestID = UUID().uuidString
        diarizationRequestID = requestID
        diarizationOperationInProgress = true
        diarizationStatus = "processing"
        do {
            let segmentsData = try encoder.encode(segments)
            let segmentsJSON = try decoder.decode(JSONValue.self, from: segmentsData)
            try send(WorkerCommand(
                requestID: requestID, command: "diarize",
                payload: ["audio_path": .string(audioPath), "segments": segmentsJSON]
            ))
        } catch {
            diarizationRequestID = nil
            diarizationOperationInProgress = false
            diarizationStatus = "failed"
            throw error
        }
        return requestID
    }

    @discardableResult
    func transcribe(audioURL: URL, modelName: String, language: String? = nil) throws -> String {
        try transcribe(
            audioURL: audioURL,
            modelName: modelName,
            language: language,
            domain: "general",
            extraTerms: ""
        )
    }

    @discardableResult
    func transcribe(
        audioURL: URL,
        modelName: String,
        language: String?,
        domain: String,
        extraTerms: String
    ) throws -> String {
        guard activeRequestID == nil else { throw WorkerSupervisorError.transcriptionAlreadyActive }
        guard !modelOperationInProgress else { throw WorkerSupervisorError.modelOperationActive }
        let requestID = UUID().uuidString
        var payload: [String: JSONValue] = [
            "audio_path": .string(audioURL.path),
            "model_name": .string(modelName),
            "skip_llm": .bool(!llmPunctuationEnabled),
        ]
        if let language, !language.isEmpty { payload["language"] = .string(language) }
        if !domain.isEmpty { payload["domain"] = .string(domain) }
        if !extraTerms.isEmpty { payload["extra_terms"] = .string(extraTerms) }
        progress = 0
        partialText = ""
        resultText = ""
        jobStatus = "Submitting"
        activeRequestID = requestID
        activeTranscriptionContext = ActiveTranscriptionContext(
            requestID: requestID,
            audioURL: audioURL,
            modelName: modelName,
            language: language,
            domain: domain.isEmpty ? "general" : domain,
            extraTerms: extraTerms
        )
        do {
            try send(WorkerCommand(requestID: requestID, command: "transcribe", payload: payload))
        } catch {
            activeRequestID = nil
            activeTranscriptionContext = nil
            throw error
        }
        return requestID
    }

    func cancel() throws {
        guard let activeJobID else { return }
        try send(WorkerCommand(
            requestID: UUID().uuidString,
            command: "cancel",
            payload: ["job_id": .string(activeJobID)]
        ))
    }

    func addTerminalObserver(
        _ observer: @escaping @MainActor @Sendable (String?, String) -> Void
    ) -> UUID {
        let id = UUID()
        terminalObservers[id] = observer
        return id
    }

    func addLostObserver(_ observer: @escaping @MainActor @Sendable (String) -> Void) -> UUID {
        let id = UUID()
        lostObservers[id] = observer
        return id
    }

    func addReadyObserver(_ observer: @escaping @MainActor @Sendable () -> Void) -> UUID {
        let id = UUID()
        readyObservers[id] = observer
        return id
    }

    func addUnavailableObserver(
        _ observer: @escaping @MainActor @Sendable (WorkerState) -> Void
    ) -> UUID {
        let id = UUID()
        unavailableObservers[id] = observer
        return id
    }

    func removeObserver(_ id: UUID) {
        terminalObservers[id] = nil
        lostObservers[id] = nil
        readyObservers[id] = nil
        unavailableObservers[id] = nil
    }

    func stop() {
        isStopping = true
        launchConfiguration = nil
        output?.readabilityHandler = nil
        errorOutput?.readabilityHandler = nil
        try? input?.close()
        if let process, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        reset(state: .stopped)
    }

    private func send(_ command: WorkerCommand) throws {
        guard let input else { throw CocoaError(.fileNoSuchFile) }
        var data = try encoder.encode(command)
        data.append(0x0A)
        try input.write(contentsOf: data)
    }

    private func consume(_ data: Data) {
        bufferedOutput.append(data)
        while let newline = bufferedOutput.firstIndex(of: 0x0A) {
            let line = bufferedOutput[..<newline]
            bufferedOutput.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            do {
                let event = try decoder.decode(WorkerEvent.self, from: line)
                lastEvent = event
                apply(event)
            } catch {
                failWorker("Invalid Worker event: \(error.localizedDescription)")
            }
        }
    }

    private func consumeDiagnostics(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        diagnostics.append(text)
        if diagnostics.count > 20_000 {
            diagnostics = String(diagnostics.suffix(20_000))
        }
    }

    private func apply(_ event: WorkerEvent) {
        switch event.event {
        case "ready":
            state = .ready
            workerReadyHandler?()
            for observer in readyObservers.values { observer() }
        case "capabilities":
            if case .object(let diarization) = event.payload["diarization"] {
                diarizationAvailable = diarization["available"] == .bool(true)
                diarizationCapabilityMessage = diarization["message"]?.string
                    ?? "Diarization capability unavailable"
            }
        case "model_status", "model_ready":
            guard event.requestID == modelRequestID else { return }
            modelReadiness = event.payload["status"]?.string ?? (event.event == "model_ready" ? "ready" : "unknown")
            modelReadinessMessage = switch modelReadiness {
            case "ready": "Model cache verified"
            case "cached": "Model cached; warmup available"
            case "needs_download": "Model download required on first warmup"
            default: modelReadiness
            }
            modelOperationInProgress = false
            modelRequestID = nil
        case "diarization_ready":
            guard event.requestID == diarizationRequestID else { return }
            diarizationStatus = event.payload["cached"] == .bool(true) ? "ready" : "needs_download"
            diarizationOperationInProgress = false
            diarizationRequestID = nil
        case "diarized":
            guard event.requestID == diarizationRequestID else { return }
            diarizationStatus = "ready"
            diarizationOperationInProgress = false
            diarizationRequestID = nil
            diarizedSegments = Self.parseSegments(event.payload["segments"])
        case "accepted":
            guard event.requestID == activeRequestID else { return }
            activeJobID = event.payload["job_id"]?.string
            jobStatus = "Queued"
        case "status":
            guard event.requestID == activeRequestID else { return }
            jobStatus = event.payload["status"]?.string ?? event.payload["msg"]?.string ?? "Running"
        case "progress":
            guard event.requestID == activeRequestID else { return }
            let done = event.payload["done"]?.number ?? 0
            let total = event.payload["total"]?.number ?? 0
            progress = total > 0 ? min(done / total, 1) : 0
            partialText = event.payload["text"]?.string ?? partialText
            jobStatus = "Transcribing"
        case "completed":
            guard event.requestID == activeRequestID else { return }
            resultText = event.payload["text"]?.string ?? ""
            progress = 1
            jobStatus = "Completed"
            activeJobID = nil
            if let context = activeTranscriptionContext, context.requestID == event.requestID {
                let info: [String: JSONValue]
                if case .object(let value) = event.payload["info"] { info = value } else { info = [:] }
                let segments = Self.parseSegments(info["segments"])
                let completed = CompletedTranscription(
                    audioURL: context.audioURL,
                    modelName: context.modelName,
                    language: event.payload["language"]?.string ?? context.language,
                    text: resultText,
                    segments: segments,
                    durationSeconds: info["duration_seconds"]?.number,
                    domain: info["domain"]?.string ?? context.domain,
                    extraTerms: info["extra_terms"]?.string ?? context.extraTerms
                )
                latestCompletedTranscription = completed
                transcriptionCompletedHandler?(completed)
                completionRevision += 1
            }
            activeTranscriptionContext = nil
            completeRequestIfMatching(event.requestID)
        case "cancelled":
            guard event.requestID == activeRequestID else { return }
            jobStatus = "Cancelled"
            activeJobID = nil
            activeTranscriptionContext = nil
            unsuccessfulTerminalRevision += 1
            completeRequestIfMatching(event.requestID)
        case "failed", "protocol_error":
            if event.requestID == modelRequestID {
                modelReadiness = "failed"
                modelReadinessMessage = event.payload["message"]?.string ?? "Model operation failed"
                modelOperationInProgress = false
                modelRequestID = nil
                return
            }
            if event.requestID == diarizationRequestID {
                diarizationStatus = "failed"
                diarizationFailureMessage = event.payload["message"]?.string ?? "Diarization failed"
                diarizationOperationInProgress = false
                diarizationRequestID = nil
                return
            }
            guard event.requestID == activeRequestID else { return }
            jobStatus = event.payload["message"]?.string ?? "Failed"
            activeJobID = nil
            activeTranscriptionContext = nil
            unsuccessfulTerminalRevision += 1
            completeRequestIfMatching(event.requestID)
        default: break
        }
    }

    private static func parseSegments(_ value: JSONValue?) -> [TranscriptionSegment] {
        guard case .array(let values) = value else { return [] }
        return values.compactMap { value in
            guard case .object(let segment) = value,
                  let start = segment["start"]?.number,
                  let end = segment["end"]?.number,
                  let text = segment["text"]?.string,
                  start >= 0, end >= start else { return nil }
            return TranscriptionSegment(start: start, end: end, text: text, speaker: segment["speaker"]?.string)
        }
    }

    private func completeRequestIfMatching(_ requestID: String?) {
        guard requestID == activeRequestID else { return }
        activeRequestID = nil
        jobTerminalHandler?(requestID)
        for observer in terminalObservers.values { observer(requestID, jobStatus) }
    }

    private func didTerminate(_ terminatedProcess: Process, status: Int32) {
        guard process === terminatedProcess else { return }
        output?.readabilityHandler = nil
        errorOutput?.readabilityHandler = nil
        process = nil
        input = nil
        output = nil
        errorOutput = nil

        guard !isStopping, status != 0, let configuration = launchConfiguration else {
            reset(state: status == 0 || isStopping ? .stopped : .failed("Worker exited with status \(status)"))
            return
        }
        guard restartCount < maximumRestartAttempts else {
            reset(state: .failed("Worker exited with status \(status) after \(restartCount) restart attempts"))
            return
        }

        restartCount += 1
        state = .restarting(restartCount)
        loseActiveRequest()
        do {
            try launch(configuration, isRestart: true)
        } catch {
            reset(state: .failed("Worker restart failed: \(error.localizedDescription)"))
        }
    }

    private func reset(state: WorkerState) {
        self.state = state
        loseActiveRequest()
        if case .failed = state { notifyUnavailable(state) }
        if state == .stopped { notifyUnavailable(state) }
        output?.readabilityHandler = nil
        errorOutput?.readabilityHandler = nil
        process = nil
        input = nil
        output = nil
        errorOutput = nil
        bufferedOutput.removeAll(keepingCapacity: true)
        activeJobID = nil
        activeRequestID = nil
        if modelOperationInProgress {
            modelReadiness = "failed"
            modelReadinessMessage = "Model operation interrupted because Worker became unavailable"
        }
        modelOperationInProgress = false
        modelRequestID = nil
    }

    private func notifyUnavailable(_ state: WorkerState) {
        workerUnavailableHandler?(state)
        for observer in unavailableObservers.values { observer(state) }
    }

    private func failWorker(_ message: String) {
        isStopping = true
        output?.readabilityHandler = nil
        errorOutput?.readabilityHandler = nil
        try? input?.close()
        if let process, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        reset(state: .failed(message))
    }

    private func loseActiveRequest() {
        let requestID = activeRequestID
        if requestID != nil { unsuccessfulTerminalRevision += 1 }
        activeRequestID = nil
        activeJobID = nil
        activeTranscriptionContext = nil
        if let requestID { jobLostHandler?(requestID) }
        if let requestID {
            for observer in lostObservers.values { observer(requestID) }
        }
    }
}
