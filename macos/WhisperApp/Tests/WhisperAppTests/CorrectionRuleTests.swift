import Foundation
import Testing
@testable import WhisperApp

/// Synthetic rules only — no real names or user data.
@MainActor
struct CorrectionRuleTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func validationRejectsBadRulesWithReasons() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CorrectionRuleStore(fileURL: directory.appendingPathComponent("correction-rules.json"))
        try store.add(wrong: " Articature ", right: "Architecture")

        #expect(throws: CorrectionRuleError.emptyWrong) { try store.add(wrong: "  ", right: "X") }
        #expect(throws: CorrectionRuleError.emptyRight) { try store.add(wrong: "Zyn", right: " ") }
        #expect(throws: CorrectionRuleError.wrongTooShort) { try store.add(wrong: "Z", right: "Zyntrix") }
        #expect(throws: CorrectionRuleError.sameAsRight) { try store.add(wrong: "Zyntrix", right: "Zyntrix") }
        #expect(throws: CorrectionRuleError.duplicateWrong("Articature")) {
            try store.add(wrong: "Articature", right: "Other")
        }
        #expect(CorrectionRuleError.wrongTooShort.localizedDescription.contains("2"))
        #expect(store.rules.map(\.wrong) == ["Articature"])
    }

    @Test func persistsTogglesAndSendsOnlyEnabledRules() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("correction-rules.json")
        let store = CorrectionRuleStore(fileURL: url)
        try store.add(wrong: "Articature", right: "Architecture")
        try store.add(wrong: "朋友放入", right: "文件放入")
        try store.toggle(store.rules[0])

        let restored = CorrectionRuleStore(fileURL: url)
        #expect(restored.rules.map(\.isEnabled) == [false, true])
        #expect(restored.activeCorrections == [CorrectionPair(wrong: "朋友放入", right: "文件放入")])
        let raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        #expect(raw.allSatisfy { Set($0.keys) == ["id", "wrong", "right", "isEnabled", "createdAt"] })

        try restored.remove(restored.rules[1])
        #expect(restored.activeCorrections.isEmpty)
    }

    @Test func unreadableFileRunsWithEmptyRulesAndReportsError() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("correction-rules.json")
        try Data("{broken".utf8).write(to: url)

        let store = CorrectionRuleStore(fileURL: url)

        #expect(store.loadError != nil)
        #expect(store.activeCorrections.isEmpty)
    }

    // MARK: - 建議詞彙一併加入修正規則

    private func loadedSuggestions(_ reply: String) async -> VocabularySuggestionController {
        let controller = VocabularySuggestionController(
            clients: [.openAI: StubSuggestionClient(reply: reply)], credentials: { _ in "key" }
        )
        await controller.requestSuggestions(
            transcriptionID: UUID(), transcript: "逐字稿", provider: .openAI, existingTerms: []
        )
        return controller
    }

    @Test func optedInSuggestionCreatesHeardAsRules() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let vocabulary = VocabularyStore(fileURL: directory.appendingPathComponent("vocabulary.json"))
        let corrections = CorrectionRuleStore(fileURL: directory.appendingPathComponent("correction-rules.json"))
        let controller = await loadedSuggestions(
            #"[{"term":"FTP","heard_as":["Free","FTP"," Fre e "]},{"term":"KM","heard_as":["Kay Em"]}]"#
        )
        let ftp = try #require(controller.suggestions.first)
        #expect(controller.correctionOptIns.isEmpty)   // 預設不勾選

        controller.setIncludesCorrections(true, for: ftp)
        controller.add(ftp, to: vocabulary, corrections: corrections)

        #expect(vocabulary.terms.map(\.value) == ["FTP"])
        #expect(corrections.activeCorrections == [
            CorrectionPair(wrong: "Free", right: "FTP"), CorrectionPair(wrong: "Fre e", right: "FTP"),
        ])  // heard_as 與 term 相同者略過
        #expect(controller.addError == nil)

        controller.add(try #require(controller.suggestions.first), to: vocabulary, corrections: corrections)
        #expect(vocabulary.terms.map(\.value) == ["FTP", "KM"])
        #expect(corrections.rules.count == 2)          // 未勾選只加詞
    }

    @Test func addAllCreatesRulesOnlyForOptedInSuggestions() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let vocabulary = VocabularyStore(fileURL: directory.appendingPathComponent("vocabulary.json"))
        let corrections = CorrectionRuleStore(fileURL: directory.appendingPathComponent("correction-rules.json"))
        try corrections.add(wrong: "Kay Em", right: "Other")
        let controller = await loadedSuggestions(
            #"[{"term":"FTP","heard_as":["Free"]},{"term":"KM","heard_as":["Kay Em"]},{"term":"Zyntrix","heard_as":["Zyn trix"]}]"#
        )
        controller.setIncludesCorrections(true, for: controller.suggestions[1])
        controller.setIncludesCorrections(true, for: controller.suggestions[2])

        controller.addAll(to: vocabulary, corrections: corrections)

        #expect(vocabulary.terms.map(\.value) == ["FTP", "KM", "Zyntrix"])
        #expect(corrections.rules.map(\.wrong) == ["Kay Em", "Zyn trix"])
        #expect(controller.addError?.contains("Kay Em") == true)   // 重複規則：詞已加入、原因有顯示
        #expect(controller.correctionOptIns.isEmpty)
    }

    @Test func optInIgnoredForSuggestionWithoutHeardAs() async throws {
        let controller = await loadedSuggestions(#"[{"term":"FTP"}]"#)
        controller.setIncludesCorrections(true, for: controller.suggestions[0])
        #expect(controller.correctionOptIns.isEmpty)
    }

    // MARK: - transcribe payload

    @Test func everyTranscribeRequestCarriesOnlyEnabledCorrections() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("echo_worker.py")
        try echoWorkerScript.write(to: script, atomically: true, encoding: .utf8)
        let audio = directory.appendingPathComponent("a.wav")
        try Data("RIFF".utf8).write(to: audio)
        let corrections = CorrectionRuleStore(fileURL: directory.appendingPathComponent("correction-rules.json"))
        try corrections.add(wrong: "Articature", right: "Architecture")
        try corrections.add(wrong: "Free", right: "FTP")
        try corrections.toggle(corrections.rules[1])
        let supervisor = WorkerSupervisor()
        supervisor.correctionsProvider = { [weak corrections] in corrections?.activeCorrections ?? [] }
        try supervisor.start(
            pythonURL: URL(fileURLWithPath: "/usr/bin/python3"), workerURL: script, workingDirectory: directory
        )
        defer { supervisor.stop() }
        try await waitUntil { supervisor.state == .ready }

        // Full entry point (recording / mixed / file / batch / re-transcribe).
        _ = try supervisor.transcribe(
            audioURL: audio, modelName: "base", language: "zh", domain: "general", extraTerms: "Zyntrix"
        )
        try await waitUntil { supervisor.jobStatus == "Completed" }
        #expect(supervisor.resultText == #"[{"right": "Architecture", "wrong": "Articature"}]"#)

        // Short form, via the AudioTranscribing protocol used by the recording controllers.
        let transcriber: any AudioTranscribing = supervisor
        _ = try transcriber.transcribe(audioURL: audio, modelName: "base", language: nil)
        try await waitUntil { supervisor.activeRequestID == nil && supervisor.jobStatus == "Completed" }
        #expect(supervisor.resultText == #"[{"right": "Architecture", "wrong": "Articature"}]"#)

        // No enabled rules → field omitted, payload identical to before.
        try corrections.toggle(corrections.rules[0])
        _ = try supervisor.transcribe(audioURL: audio, modelName: "base", language: "zh")
        try await waitUntil { supervisor.activeRequestID == nil && supervisor.resultText == "absent" }
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            if clock.now >= deadline { throw WaitTimeout() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private struct WaitTimeout: Error {}

    private var echoWorkerScript: String {
        """
        import json, sys
        def emit(request_id, event, payload):
            print(json.dumps({"protocol":"whisper.worker","version":1,"type":"event","request_id":request_id,"event":event,"payload":payload}), flush=True)
        emit("worker", "ready", {"status":"ready"})
        for line in sys.stdin:
            command = json.loads(line)
            if command["command"] == "transcribe":
                corrections = command["payload"].get("corrections")
                text = "absent" if corrections is None else json.dumps(corrections, ensure_ascii=False, sort_keys=True)
                emit(command["request_id"], "accepted", {"job_id":"job-1","status":"queued"})
                emit(command["request_id"], "completed", {"job_id":"job-1","text":text,"language":"zh","info":{}})
        """
    }
}

private struct StubSuggestionClient: VocabularySuggesting {
    let providerName = "stub"
    let reply: String
    func suggest(transcript: String, apiKey: String) async throws -> String { reply }
}
