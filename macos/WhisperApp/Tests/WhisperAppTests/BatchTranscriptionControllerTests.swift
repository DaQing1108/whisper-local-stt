import Foundation
import Testing
@testable import WhisperApp

@MainActor
struct BatchTranscriptionControllerTests {
    @Test func enforcesCapacityWithoutMutatingExistingQueue() throws {
        let controller = BatchTranscriptionController(worker: WorkerSupervisor(), capacity: 2)
        let original = [URL(fileURLWithPath: "/tmp/original.wav")]
        try controller.replaceFiles(original)

        #expect(throws: BatchTranscriptionError.capacityExceeded(2)) {
            try controller.replaceFiles([
                URL(fileURLWithPath: "/tmp/1.wav"),
                URL(fileURLWithPath: "/tmp/2.wav"),
                URL(fileURLWithPath: "/tmp/3.wav"),
            ])
        }
        #expect(controller.items.map(\.url) == original)
    }

    @Test func cancelPendingPreservesOrderAndMarksEveryUnsubmittedItem() throws {
        let controller = BatchTranscriptionController(worker: WorkerSupervisor())
        let urls = ["a.wav", "b.wav", "c.wav"].map { URL(fileURLWithPath: "/tmp/\($0)") }
        try controller.replaceFiles(urls)

        controller.cancelPending()

        #expect(controller.items.map(\.url) == urls)
        #expect(controller.items.allSatisfy { $0.status == .cancelled })
        #expect(!controller.isRunning)
    }

    @Test func submitsStrictlyInOrderAndMapsCompletedTerminalState() async throws {
        let temporary = try makeTemporaryWorker(script: completingWorker)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let worker = WorkerSupervisor()
        try worker.start(
            pythonURL: URL(fileURLWithPath: "/usr/bin/python3"),
            workerURL: temporary.appendingPathComponent("worker.py"), workingDirectory: temporary
        )
        try await waitUntil { worker.state == .ready }
        let controller = BatchTranscriptionController(worker: worker)
        let urls = ["a.wav", "b.wav"].map { temporary.appendingPathComponent($0) }
        try controller.replaceFiles(urls)
        try controller.start(model: "base", language: "zh", domain: "business", extraTerms: "VIA")
        try await waitUntil { !controller.isRunning }

        #expect(controller.items.map(\.url) == urls)
        #expect(controller.items.allSatisfy { $0.status == .completed })
        worker.stop()
    }

    @Test func workerStopTerminatesRunningAndPendingItemsAsFailed() async throws {
        let temporary = try makeTemporaryWorker(script: hangingWorker)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let worker = WorkerSupervisor()
        try worker.start(
            pythonURL: URL(fileURLWithPath: "/usr/bin/python3"),
            workerURL: temporary.appendingPathComponent("worker.py"), workingDirectory: temporary
        )
        try await waitUntil { worker.state == .ready }
        let controller = BatchTranscriptionController(worker: worker)
        try controller.replaceFiles([
            temporary.appendingPathComponent("a.wav"), temporary.appendingPathComponent("b.wav")
        ])
        try controller.start(model: "base", language: nil, domain: "general", extraTerms: "")
        try await waitUntil { controller.items.first?.status == .running }

        worker.stop()

        #expect(!controller.isRunning)
        #expect(controller.items.allSatisfy { $0.status == .failed })
    }

    private func makeTemporaryWorker(script: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try script.write(to: directory.appendingPathComponent("worker.py"), atomically: true, encoding: .utf8)
        return directory
    }

    private func waitUntil(
        timeout: Duration = .seconds(5), condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            if clock.now >= deadline { throw BatchTestError.timeout }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private enum BatchTestError: Error { case timeout }

    private var completingWorker: String {
        """
        import json, sys
        def emit(r, e, p):
            print(json.dumps({"protocol":"whisper.worker","version":1,"type":"event","request_id":r,"event":e,"payload":p}), flush=True)
        emit("worker", "ready", {"status":"ready"})
        for line in sys.stdin:
            c = json.loads(line)
            if c["command"] == "transcribe":
                r = c["request_id"]
                emit(r, "accepted", {"job_id":r})
                emit(r, "completed", {"job_id":r,"text":c["payload"]["audio_path"],"language":"zh","info":{"segments":[]}})
        """
    }

    private var hangingWorker: String {
        """
        import json, sys
        def emit(r, e, p):
            print(json.dumps({"protocol":"whisper.worker","version":1,"type":"event","request_id":r,"event":e,"payload":p}), flush=True)
        emit("worker", "ready", {"status":"ready"})
        for line in sys.stdin:
            c = json.loads(line)
            if c["command"] == "transcribe":
                emit(c["request_id"], "accepted", {"job_id":c["request_id"]})
        """
    }
}
