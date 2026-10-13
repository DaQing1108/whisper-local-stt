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
}
