import Foundation
import Testing
@testable import WhisperApp

@MainActor
struct WorkerSupervisorTests {
    @Test
    func startsWorkerReceivesReadyAndPongThenStops() async throws {
        let packageDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let repository = packageDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let supervisor = WorkerSupervisor()

        try supervisor.start(
            pythonURL: URL(fileURLWithPath: "/usr/bin/python3"),
            workerURL: repository.appendingPathComponent("worker_entrypoint.py"),
            workingDirectory: repository
        )

        try await waitUntil { supervisor.state == .ready }
        let requestID = try supervisor.ping()
        try await waitUntil {
            supervisor.lastEvent?.event == "pong" && supervisor.lastEvent?.requestID == requestID
        }
        let capabilitiesID = try supervisor.requestCapabilities()
        try await waitUntil {
            supervisor.lastEvent?.event == "capabilities"
                && supervisor.lastEvent?.requestID == capabilitiesID
        }
        #expect(!supervisor.diarizationAvailable)
        #expect(supervisor.diarizationCapabilityMessage.contains("does not include torch"))
        supervisor.stop()

        #expect(supervisor.state == .stopped)
    }

    @Test
    func transcribeTracksAcceptedProgressAndCompletedEvents() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let audio = temporary.appendingPathComponent("sample.wav")
        try Data("audio".utf8).write(to: audio)
        let workerScript = temporary.appendingPathComponent("fake_worker.py")
        try fakeWorkerScript.write(to: workerScript, atomically: true, encoding: .utf8)
        let supervisor = WorkerSupervisor()
        var completed: WorkerSupervisor.CompletedTranscription?
        supervisor.transcriptionCompletedHandler = { completed = $0 }

        try supervisor.start(
            pythonURL: URL(fileURLWithPath: "/usr/bin/python3"),
            workerURL: workerScript,
            workingDirectory: temporary
        )
        try await waitUntil { supervisor.state == .ready }
        _ = try supervisor.transcribe(
            audioURL: audio, modelName: "base", language: "zh",
            domain: "technology", extraTerms: "VIA"
        )
        try await waitUntil { supervisor.jobStatus == "Completed" }

        #expect(supervisor.resultText == "測試完成")
        #expect(supervisor.progress == 1)
        #expect(supervisor.activeJobID == nil)
        #expect(completed?.audioURL == audio)
        #expect(completed?.modelName == "base")
        #expect(completed?.language == "zh")
        #expect(completed?.text == "測試完成")
        #expect(completed?.segments == [TranscriptionSegment(start: 0.25, end: 1.5, text: "測試完成")])
        #expect(completed?.durationSeconds == 1.5)
        #expect(completed?.domain == "technology")
        #expect(completed?.extraTerms == "VIA")
        _ = try supervisor.requestModelStatus(modelName: "base")
        try await waitUntil { supervisor.modelReadiness == "cached" }
        #expect(supervisor.modelReadinessMessage.contains("cached"))
        _ = try supervisor.warmupModel(modelName: "base")
        try await waitUntil { supervisor.modelReadiness == "ready" }
        supervisor.stop()
    }

    @Test
    func injectsKeychainCredentialIntoWorkerEnvironmentAndEnablesLLMPunctuation() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let audio = temporary.appendingPathComponent("sample.wav")
        try Data("audio".utf8).write(to: audio)
        let workerScript = temporary.appendingPathComponent("llm_env_echo.py")
        try llmEnvEchoWorkerScript.write(to: workerScript, atomically: true, encoding: .utf8)
        let supervisor = WorkerSupervisor()
        let fakeKey = "sk-test-anthropic-fake-key-1234567890"
        supervisor.llmCredentialLoader = { provider in provider == .anthropic ? fakeKey : nil }

        try supervisor.start(
            pythonURL: URL(fileURLWithPath: "/usr/bin/python3"),
            workerURL: workerScript, workingDirectory: temporary
        )
        try await waitUntil { supervisor.state == .ready }
        #expect(supervisor.llmPunctuationEnabled)
        _ = try supervisor.transcribe(audioURL: audio, modelName: "base")
        try await waitUntil { supervisor.jobStatus == "Completed" }

        #expect(supervisor.partialText == "skip_llm=False anthropic_seen=True openai_seen=False")
        // The key must never surface anywhere observable outside process.environment.
        #expect(!supervisor.diagnostics.contains(fakeKey))
        supervisor.stop()
    }

    @Test
    func injectsOpenAICredentialWhenAnthropicIsNotConfigured() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let audio = temporary.appendingPathComponent("sample.wav")
        try Data("audio".utf8).write(to: audio)
        let workerScript = temporary.appendingPathComponent("llm_env_echo_openai.py")
        try llmEnvEchoWorkerScript.write(to: workerScript, atomically: true, encoding: .utf8)
        let supervisor = WorkerSupervisor()
        let fakeKey = "sk-test-openai-fake-key-1234567890"
        supervisor.llmCredentialLoader = { provider in provider == .openAI ? fakeKey : nil }

        try supervisor.start(
            pythonURL: URL(fileURLWithPath: "/usr/bin/python3"),
            workerURL: workerScript, workingDirectory: temporary
        )
        try await waitUntil { supervisor.state == .ready }
        #expect(supervisor.llmPunctuationEnabled)
        _ = try supervisor.transcribe(audioURL: audio, modelName: "base")
        try await waitUntil { supervisor.jobStatus == "Completed" }

        #expect(supervisor.partialText == "skip_llm=False anthropic_seen=False openai_seen=True")
        supervisor.stop()
    }

    @Test
    func withoutStoredCredentialSkipsLLMAndLeavesWorkerEnvironmentUnset() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let audio = temporary.appendingPathComponent("sample.wav")
        try Data("audio".utf8).write(to: audio)
        let workerScript = temporary.appendingPathComponent("llm_env_echo_none.py")
        try llmEnvEchoWorkerScript.write(to: workerScript, atomically: true, encoding: .utf8)
        let supervisor = WorkerSupervisor()
        supervisor.llmCredentialLoader = { _ in nil }

        try supervisor.start(
            pythonURL: URL(fileURLWithPath: "/usr/bin/python3"),
            workerURL: workerScript, workingDirectory: temporary
        )
        try await waitUntil { supervisor.state == .ready }
        #expect(!supervisor.llmPunctuationEnabled)
        _ = try supervisor.transcribe(audioURL: audio, modelName: "base")
        try await waitUntil { supervisor.jobStatus == "Completed" }

        #expect(supervisor.partialText == "skip_llm=True anthropic_seen=False openai_seen=False")
        supervisor.stop()
    }

    @Test
    func discoversWorkerByWalkingUpFromSwiftPackage() throws {
        let packageDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let configuration = try WorkerLaunchConfiguration.discover(currentDirectory: packageDirectory)

        #expect(configuration.executableURL.path == "/usr/bin/python3")
        #expect(configuration.arguments.last?.hasSuffix("worker_entrypoint.py") == true)
        #expect(FileManager.default.fileExists(
            atPath: configuration.workingDirectory.appendingPathComponent("worker_protocol.py").path
        ))
    }

    @Test
    func prefersPackagedWorkerExecutableFromEnvironment() throws {
        let configuration = try WorkerLaunchConfiguration.discover(
            environment: ["WHISPER_WORKER_EXECUTABLE": "/bin/sh"]
        )

        #expect(configuration.executableURL.path == "/bin/sh")
        #expect(configuration.arguments.isEmpty)
    }

    @Test
    func discoversWorkerInsideAppResources() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let runtime = temporary.appendingPathComponent("WhisperWorker", isDirectory: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let executable = runtime.appendingPathComponent("WhisperWorker")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let configuration = try WorkerLaunchConfiguration.discover(
            environment: [:],
            currentDirectory: temporary,
            bundledResourceURL: temporary
        )

        #expect(configuration.executableURL == executable)
        #expect(configuration.arguments.isEmpty)
    }

    @Test
    func capturesDiagnosticsAndRestartsAfterCrash() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let workerScript = temporary.appendingPathComponent("crash_once.py")
        try crashOnceWorkerScript.write(to: workerScript, atomically: true, encoding: .utf8)
        let supervisor = WorkerSupervisor()

        try supervisor.start(
            pythonURL: URL(fileURLWithPath: "/usr/bin/python3"),
            workerURL: workerScript,
            workingDirectory: temporary
        )
        try await waitUntil { supervisor.state == .ready && supervisor.restartCount == 1 }

        #expect(supervisor.diagnostics.contains("simulated crash"))
        supervisor.stop()
        #expect(supervisor.state == .stopped)
    }

    @Test
    func stoppingWorkerTerminatesInFlightModelOperation() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let script = temporary.appendingPathComponent("hanging_model.py")
        try hangingModelWorkerScript.write(to: script, atomically: true, encoding: .utf8)
        let supervisor = WorkerSupervisor()
        try supervisor.start(
            pythonURL: URL(fileURLWithPath: "/usr/bin/python3"),
            workerURL: script, workingDirectory: temporary
        )
        try await waitUntil { supervisor.state == .ready }
        try supervisor.warmupModel(modelName: "base")
        #expect(supervisor.modelOperationInProgress)

        supervisor.stop()

        #expect(!supervisor.modelOperationInProgress)
        #expect(supervisor.modelReadiness == "failed")
    }

    @Test
    func malformedEventLosesActiveRequestAndSignalsWorkerUnavailable() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let audio = temporary.appendingPathComponent("sample.wav")
        try Data("audio".utf8).write(to: audio)
        let workerScript = temporary.appendingPathComponent("malformed_worker.py")
        try malformedWorkerScript.write(to: workerScript, atomically: true, encoding: .utf8)
        let supervisor = WorkerSupervisor()
        var lostRequestID: String?
        var unavailableState: WorkerState?
        supervisor.jobLostHandler = { lostRequestID = $0 }
        supervisor.workerUnavailableHandler = { unavailableState = $0 }

        try supervisor.start(
            pythonURL: URL(fileURLWithPath: "/usr/bin/python3"),
            workerURL: workerScript,
            workingDirectory: temporary
        )
        try await waitUntil { supervisor.state == .ready }
        let requestID = try supervisor.transcribe(audioURL: audio, modelName: "base")
        try await waitUntil {
            if case .failed = supervisor.state { return true }
            return false
        }

        #expect(lostRequestID == requestID)
        #expect(unavailableState == supervisor.state)
        #expect(supervisor.activeRequestID == nil)
    }

    @Test
    func asyncTranscriptionFailurePublishesAnUnsuccessfulTerminalRevision() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let audio = temporary.appendingPathComponent("sample.wav")
        try Data("audio".utf8).write(to: audio)
        let workerScript = temporary.appendingPathComponent("failed_worker.py")
        try failedWorkerScript.write(to: workerScript, atomically: true, encoding: .utf8)
        let supervisor = WorkerSupervisor()

        try supervisor.start(
            pythonURL: URL(fileURLWithPath: "/usr/bin/python3"),
            workerURL: workerScript,
            workingDirectory: temporary
        )
        try await waitUntil { supervisor.state == .ready }
        _ = try supervisor.transcribe(audioURL: audio, modelName: "base")
        try await waitUntil { supervisor.unsuccessfulTerminalRevision == 1 }

        #expect(supervisor.activeRequestID == nil)
        #expect(supervisor.jobStatus == "simulated transcription failure")
        supervisor.stop()
    }

    private func waitUntil(
        timeout: Duration = .seconds(5),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            if clock.now >= deadline { throw TestError.timeout }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private enum TestError: Error { case timeout }

    private var fakeWorkerScript: String {
        """
        import json, sys
        def emit(request_id, event, payload):
            print(json.dumps({"protocol":"whisper.worker","version":1,"type":"event","request_id":request_id,"event":event,"payload":payload}), flush=True)
        emit("worker", "ready", {"status":"ready"})
        for line in sys.stdin:
            command = json.loads(line)
            if command["command"] == "transcribe":
                request_id = command["request_id"]
                emit(request_id, "accepted", {"job_id":"job-1","status":"queued"})
                emit(request_id, "progress", {"job_id":"job-1","done":1,"total":2,"text":"測試"})
                assert command["payload"]["domain"] == "technology"
                assert command["payload"]["extra_terms"] == "VIA"
                emit(request_id, "completed", {"job_id":"job-1","text":"測試完成","language":"zh","info":{"segments":[{"start":0.25,"end":1.5,"text":"測試完成"}],"duration_seconds":1.5,"domain":"technology","extra_terms":"VIA"}})
            elif command["command"] == "ping":
                emit(command["request_id"], "pong", {})
            elif command["command"] == "model_status":
                emit(command["request_id"], "model_status", {"model_name":"base","status":"cached","cached":True,"loaded":False})
            elif command["command"] == "warmup_model":
                emit(command["request_id"], "model_ready", {"model_name":"base","status":"ready","cached":True,"loaded":True})
        """
    }

    private var llmEnvEchoWorkerScript: String {
        """
        import json, os, sys
        def emit(request_id, event, payload):
            print(json.dumps({"protocol":"whisper.worker","version":1,"type":"event","request_id":request_id,"event":event,"payload":payload}), flush=True)
        emit("worker", "ready", {"status":"ready"})
        for line in sys.stdin:
            command = json.loads(line)
            if command["command"] == "transcribe":
                request_id = command["request_id"]
                skip_llm = command["payload"].get("skip_llm")
                anthropic_seen = bool(os.environ.get("ANTHROPIC_API_KEY"))
                openai_seen = bool(os.environ.get("OPENAI_API_KEY"))
                emit(request_id, "accepted", {"job_id":"job-1","status":"queued"})
                emit(request_id, "progress", {"job_id":"job-1","done":1,"total":1,"text":f"skip_llm={skip_llm} anthropic_seen={anthropic_seen} openai_seen={openai_seen}"})
                emit(request_id, "completed", {"job_id":"job-1","text":"測試完成","language":"zh","info":{"segments":[],"duration_seconds":1.0}})
        """
    }

    private var crashOnceWorkerScript: String {
        """
        import json, pathlib, sys
        marker = pathlib.Path("crashed.marker")
        if not marker.exists():
            marker.write_text("1")
            print("simulated crash", file=sys.stderr, flush=True)
            raise SystemExit(17)
        print(json.dumps({"protocol":"whisper.worker","version":1,"type":"event","request_id":"worker","event":"ready","payload":{"status":"ready"}}), flush=True)
        for _ in sys.stdin:
            pass
        """
    }

    private var malformedWorkerScript: String {
        """
        import json, sys
        print(json.dumps({"protocol":"whisper.worker","version":1,"type":"event","request_id":"worker","event":"ready","payload":{"status":"ready"}}), flush=True)
        for line in sys.stdin:
            command = json.loads(line)
            if command["command"] == "transcribe":
                print("not-json", flush=True)
                for _ in sys.stdin:
                    pass
        """
    }

    private var failedWorkerScript: String {
        """
        import json, sys
        def emit(request_id, event, payload):
            print(json.dumps({"protocol":"whisper.worker","version":1,"type":"event","request_id":request_id,"event":event,"payload":payload}), flush=True)
        emit("worker", "ready", {"status":"ready"})
        for line in sys.stdin:
            command = json.loads(line)
            if command["command"] == "transcribe":
                request_id = command["request_id"]
                emit(request_id, "accepted", {"job_id":"job-fail","status":"queued"})
                emit(request_id, "failed", {"job_id":"job-fail","message":"simulated transcription failure"})
        """
    }

    private var hangingModelWorkerScript: String {
        """
        import json, sys, time
        print(json.dumps({"protocol":"whisper.worker","version":1,"type":"event","request_id":"worker","event":"ready","payload":{"status":"ready"}}), flush=True)
        for line in sys.stdin:
            command = json.loads(line)
            if command["command"] == "warmup_model":
                while True: time.sleep(1)
        """
    }
}
