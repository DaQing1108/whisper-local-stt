import Foundation
import Testing
@testable import WhisperApp

private final class RecordingSink: WorkerLogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [WorkerLogEntry] = []
    var entries: [WorkerLogEntry] { lock.withLock { storage } }
    func record(_ entry: WorkerLogEntry) { lock.withLock { storage.append(entry) } }
}

@MainActor
@Suite(.serialized)
struct WorkerDiagnosticsTests {
    @Test
    func lifecycleEventsReachLoggerWithSessionAndRequestIDs() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let script = temporary.appendingPathComponent("fake_worker.py")
        try Self.workerScript.write(to: script, atomically: true, encoding: .utf8)
        let sink = RecordingSink()
        let supervisor = WorkerSupervisor()
        supervisor.logSink = sink

        try supervisor.start(
            pythonURL: URL(fileURLWithPath: "/usr/bin/python3"),
            workerURL: script, workingDirectory: temporary
        )
        let session = supervisor.sessionID
        try await waitUntil { supervisor.state == .ready }
        let requestID = try supervisor.transcribe(audioURL: temporary.appendingPathComponent("a.wav"), modelName: "base")
        try await waitUntil { supervisor.jobStatus == "Completed" }
        supervisor.stop()

        let events = sink.entries.map(\.event)
        for expected in ["worker_start", "worker_ready", "job_submitted", "job_accepted",
                         "job_progress", "job_completed", "worker_stopped"] {
            #expect(events.contains(expected), "missing \(expected) in \(events)")
        }
        #expect(sink.entries.allSatisfy { $0.sessionID == session })
        let completed = try #require(sink.entries.first { $0.event == "job_completed" })
        #expect(completed.requestID == requestID)
        #expect(completed.jobID == "job-1")
        #expect(completed.renderedMessage.contains("session=\(session.uuidString)"))
    }

    @Test
    func eachStartMintsNewSessionID() async throws {
        let supervisor = WorkerSupervisor()
        supervisor.logSink = RecordingSink()
        let first = supervisor.sessionID
        let missing = WorkerLaunchConfiguration(
            executableURL: URL(fileURLWithPath: "/nonexistent/worker"), arguments: [],
            workingDirectory: FileManager.default.temporaryDirectory
        )
        try? supervisor.start(configuration: missing)
        #expect(supervisor.sessionID != first)
    }

    @Test
    func redactorHidesUsernameInPaths() {
        let redacted = WorkerDiagnosticsRedactor.redact(
            "open /Users/daqingliao/Documents/a.wav and '/Users/alex' end"
        )
        #expect(!redacted.contains("daqingliao"))
        #expect(!redacted.contains("alex"))
        #expect(redacted.contains("/Users/<redacted>/Documents/a.wav"))
    }

    @Test
    func exportedFileIsRedactedAndPrivate() throws {
        var exporter = WorkerDiagnosticsExporter()
        exporter.lineProvider = { ["2026 [WorkerLifecycle] event=job_failed detail=/Users/daqingliao/x.wav"] }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try exporter.export(stderrTail: "Traceback in /Users/daqingliao/app.py", directory: directory)
        let text = try String(contentsOf: url, encoding: .utf8)

        #expect(!text.contains("daqingliao"))
        #expect(text.contains("event=job_failed"))
        #expect(text.contains("/Users/<redacted>/x.wav"))
        #expect(text.contains("Worker stderr tail"))
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test
    func redactorHandlesPathVariantsAndRuntimeIdentity() {
        func redact(_ text: String) -> String {
            WorkerDiagnosticsRedactor.redact(text, userName: "zorbulax", homeDirectory: "/Volumes/h/zorbulax")
        }
        #expect(redact("/Users/Da Qing/x.wav") == "/Users/<redacted>/x.wav")
        #expect(redact("/users/O'Brien/x") == "/Users/<redacted>/x")
        #expect(redact("file:///Users/Da%20Qing/a.wav") == "file:///Users/<redacted>/a.wav")
        #expect(redact("path=%2FUsers%2Fdaqing%2Fa.wav") == "path=%2FUsers%2F<redacted>%2Fa.wav")
        #expect(redact("/var/folders/ab/cd12/T/secret-meeting.wav") == "/var/folders/ab/cd12/T/<tmp>")
        #expect(redact("/private/var/folders/ab/cd12/T/x y.wav") == "/private/var/folders/ab/cd12/T/<tmp>")
        #expect(redact("hello ZorBulax! at /Volumes/h/zorbulax/f") == "hello <user>! at <home>/f")
        for secret in ["sk-abcdEFGH_12345", "hf_AbCdEfGh1234", "Bearer abc.DEF-123", "api_key=abc123", "Token: xyz789", "secret = s3cr3t"] {
            let out = redact("failed with \(secret) end")
            #expect(out.contains("<redacted-secret>"), "\(secret) -> \(out)")
            #expect(!out.contains("abc123") && !out.contains("xyz789") && !out.contains("s3cr3t")
                && !out.contains("EFGH_12345") && !out.contains("AbCdEfGh1234") && !out.contains("abc.DEF"))
        }
    }

    @Test
    func detailIsRedactedBeforeTruncationAndNeverLeaksAtTheCut() {
        let secret = "sk-" + String(repeating: "A", count: 40)
        let padded = String(repeating: "x", count: 190) + " " + secret
        let sanitized = WorkerDiagnosticsRedactor.sanitizeDetail(padded, userName: "zorbulax", homeDirectory: "/h/zorbulax")
        #expect(sanitized.count <= WorkerDiagnosticsRedactor.maximumDetailLength + 1)
        #expect(!sanitized.contains("sk-"))
        let long = WorkerDiagnosticsRedactor.sanitizeDetail(String(repeating: "y", count: 500))
        #expect(long.hasSuffix("…") && long.count == WorkerDiagnosticsRedactor.maximumDetailLength + 1)
        #expect(WorkerDiagnosticsRedactor.sanitizeDetail(long) == long)
    }

    @Test
    func failedAndProtocolErrorDetailsAreRedactedInSinkAndRenderedMessage() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let script = temporary.appendingPathComponent("failing_worker.py")
        try Self.failingWorkerScript.write(to: script, atomically: true, encoding: .utf8)
        let sink = RecordingSink()
        let supervisor = WorkerSupervisor()
        supervisor.logSink = sink
        try supervisor.start(pythonURL: URL(fileURLWithPath: "/usr/bin/python3"), workerURL: script, workingDirectory: temporary)
        try await waitUntil { supervisor.state == .ready }

        _ = try supervisor.transcribe(audioURL: temporary.appendingPathComponent("a.wav"), modelName: "base")
        try await waitUntil { sink.entries.contains { $0.event == "job_failed" } }
        _ = try supervisor.transcribe(audioURL: temporary.appendingPathComponent("a.wav"), modelName: "base")
        try await waitUntil { sink.entries.contains { $0.event == "protocol_error" } }
        supervisor.stop()

        for event in ["job_failed", "protocol_error"] {
            let entry = try #require(sink.entries.first { $0.event == event })
            for text in [entry.detail ?? "", entry.renderedMessage] {
                #expect(!text.contains("Da Qing"), "\(event): \(text)")
                #expect(!text.contains("sk-ZZZZ"), "\(event): \(text)")
            }
            #expect(entry.detail?.contains("/Users/<redacted>/x.wav") == true)
        }
    }

    @Test
    func progressFormattingNeverTrapsOnNonFiniteOrHugeValues() async throws {
        #expect(WorkerDiagnosticsFormatting.progress(done: .nan, total: 2) == "n/a")
        #expect(WorkerDiagnosticsFormatting.progress(done: 1, total: .infinity) == "n/a")
        #expect(WorkerDiagnosticsFormatting.progress(done: 1e300, total: 2) == "n/a")
        #expect(WorkerDiagnosticsFormatting.progress(done: 1, total: 2) == "1/2")

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let script = temporary.appendingPathComponent("huge_progress.py")
        try Self.workerScript.replacingOccurrences(of: "\"done\":1,\"total\":2", with: "\"done\":1e300,\"total\":2")
            .write(to: script, atomically: true, encoding: .utf8)
        let sink = RecordingSink()
        let supervisor = WorkerSupervisor()
        supervisor.logSink = sink
        try supervisor.start(pythonURL: URL(fileURLWithPath: "/usr/bin/python3"), workerURL: script, workingDirectory: temporary)
        try await waitUntil { supervisor.state == .ready }
        _ = try supervisor.transcribe(audioURL: temporary.appendingPathComponent("a.wav"), modelName: "base")
        try await waitUntil { supervisor.jobStatus == "Completed" }
        supervisor.stop()
        let progress = try #require(sink.entries.first { $0.event == "job_progress" })
        #expect(progress.detail == "n/a")
    }

    @Test
    func automaticRestartKeepsSessionIDAndLogsWorkerRestart() async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let script = temporary.appendingPathComponent("crash_once.py")
        try Self.crashOnceScript.write(to: script, atomically: true, encoding: .utf8)
        let sink = RecordingSink()
        let supervisor = WorkerSupervisor()
        supervisor.logSink = sink
        try supervisor.start(pythonURL: URL(fileURLWithPath: "/usr/bin/python3"), workerURL: script, workingDirectory: temporary)
        let session = supervisor.sessionID
        try await waitUntil { supervisor.state == .ready && supervisor.restartCount == 1 }
        supervisor.stop()

        #expect(supervisor.sessionID == session)
        let restart = try #require(sink.entries.first { $0.event == "worker_restart" })
        #expect(restart.detail?.contains("exit_status=3") == true)
        #expect(sink.entries.allSatisfy { $0.sessionID == session })
    }

    @Test
    func repeatedExportsAreUniquePrunedToFiveAndPrivate() throws {
        var exporter = WorkerDiagnosticsExporter()
        exporter.lineProvider = { ["line"] }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let unrelated = directory.appendingPathComponent("keep-me.log")
        try Data("x".utf8).write(to: unrelated)

        var urls: [URL] = []
        for _ in 0..<8 { urls.append(try exporter.export(stderrTail: "", directory: directory)) }

        #expect(Set(urls).count == 8)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(WorkerDiagnosticsExporter.exportFilePrefix) }
        #expect(remaining.count == WorkerDiagnosticsExporter.retainedExports)
        #expect(FileManager.default.fileExists(atPath: urls.last!.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        for name in remaining {
            let mode = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)[.posixPermissions] as? Int
            #expect(mode == 0o600)
        }
    }

    @Test
    func exportTruncatesAndRedactsStderrTail() {
        var exporter = WorkerDiagnosticsExporter()
        exporter.lineProvider = { [] }
        let tail = String(repeating: "a", count: 9000) + " token=hunter2 /Users/Da Qing/y.py"
        let text = exporter.render(stderrTail: tail)
        #expect(!text.contains("hunter2") && !text.contains("Da Qing"))
        let section = text.components(separatedBy: "## Worker stderr tail (fallback)\n").last ?? ""
        #expect(section.count <= WorkerDiagnosticsExporter.stderrTailLimit + 2)
    }

    private func waitUntil(
        timeout: Duration = .seconds(20), condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            if clock.now >= deadline { throw CocoaError(.fileReadUnknown) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private static let workerScript = """
    import json, sys
    def emit(request_id, event, payload):
        print(json.dumps({"protocol":"whisper.worker","version":1,"type":"event","request_id":request_id,"event":event,"payload":payload}), flush=True)
    emit("worker", "ready", {"status":"ready"})
    for line in sys.stdin:
        command = json.loads(line)
        if command["command"] == "transcribe":
            rid = command["request_id"]
            emit(rid, "accepted", {"job_id":"job-1","status":"queued"})
            emit(rid, "progress", {"job_id":"job-1","done":1,"total":2,"text":"x"})
            emit(rid, "completed", {"job_id":"job-1","text":"ok","language":"zh","info":{"segments":[],"duration_seconds":1.0}})
    """

    private static let failingWorkerScript = """
    import json, sys
    def emit(request_id, event, payload):
        print(json.dumps({"protocol":"whisper.worker","version":1,"type":"event","request_id":request_id,"event":event,"payload":payload}), flush=True)
    emit("worker", "ready", {"status":"ready"})
    count = 0
    for line in sys.stdin:
        command = json.loads(line)
        if command["command"] == "transcribe":
            count += 1
            message = "boom /Users/Da Qing/x.wav key sk-ZZZZZZZZ12345"
            emit(command["request_id"], "failed" if count == 1 else "protocol_error", {"message": message})
    """

    private static let crashOnceScript = """
    import json, pathlib, sys
    marker = pathlib.Path(sys.argv[0] + ".seen")
    if not marker.exists():
        marker.write_text("1")
        sys.stderr.write("simulated crash\\n")
        sys.exit(3)
    print(json.dumps({"protocol":"whisper.worker","version":1,"type":"event","request_id":"worker","event":"ready","payload":{"status":"ready"}}), flush=True)
    for line in sys.stdin:
        pass
    """
}
