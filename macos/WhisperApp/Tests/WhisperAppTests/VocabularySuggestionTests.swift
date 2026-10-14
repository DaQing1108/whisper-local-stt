import Foundation
import Testing
@testable import WhisperApp

private final class CountingTransport: MeetingSummaryHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let handler: @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)

    init(handler: @escaping @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)) {
        self.handler = handler
    }

    var callCount: Int { lock.withLock { calls } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { calls += 1 }
        return try handler(request)
    }
}

private func ok(_ request: URLRequest, _ object: Any) throws -> (Data, HTTPURLResponse) {
    (try JSONSerialization.data(withJSONObject: object),
     HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
}

/// Signals `started` when a request arrives, then waits for `gate` before replying.
private final class GatedTransport: MeetingSummaryHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let started: AsyncStream<Void>.Continuation
    private let gate: AsyncStream<Void>

    init(started: AsyncStream<Void>.Continuation, gate: AsyncStream<Void>) {
        self.started = started
        self.gate = gate
    }

    var callCount: Int { lock.withLock { calls } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { calls += 1 }
        started.yield()
        var iterator = gate.makeAsyncIterator()
        _ = await iterator.next()
        return try ok(request, ["output": [["content": [["type": "output_text", "text": #"[{"term":"FTP"}]"#]]]]])
    }
}

/// OpenAI-shaped transport that returns `reply` as the model's output text.
private func openAITransport(reply: String) -> CountingTransport {
    CountingTransport { request in
        try ok(request, ["output": [["content": [["type": "output_text", "text": reply]]]]])
    }
}

private func suggestion(_ term: String) -> VocabularySuggestion {
    VocabularySuggestion(term: term, heardAs: [], reason: "")
}

@MainActor
private func makeStore() throws -> (VocabularyStore, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (VocabularyStore(fileURL: directory.appendingPathComponent("vocabulary.json")), directory)
}

private let entry = TranscriptionHistoryEntry(
    audioPath: "/tmp/meeting.wav", model: "base", language: "zh",
    text: "我們用 Free 上傳到 KM，Articature 要更新"
)

// MARK: - Parser & filter (AC-3, AC-4)

struct VocabularySuggestionParserTests {
    @Test func parsesTermHeardAsAndReason() throws {
        let parsed = try VocabularySuggestionParser.parse(
            #"[{"term": "FTP", "heard_as": ["Free"], "reason": "檔案傳輸"}]"#
        )
        #expect(parsed == [VocabularySuggestion(term: "FTP", heardAs: ["Free"], reason: "檔案傳輸")])
    }

    @Test func acceptsMarkdownCodeFence() throws {
        let parsed = try VocabularySuggestionParser.parse("```json\n[{\"term\": \"KM\"}]\n```")
        #expect(parsed.map(\.term) == ["KM"])
    }

    @Test func rejectsNonJSONAndMissingFields() {
        #expect(throws: VocabularySuggestionError.unparseable) {
            try VocabularySuggestionParser.parse("以下是建議：FTP、KM")
        }
        #expect(throws: VocabularySuggestionError.unparseable) {
            try VocabularySuggestionParser.parse(#"{"term": "FTP"}"#)
        }
        #expect(throws: VocabularySuggestionError.unparseable) {
            try VocabularySuggestionParser.parse(#"[{"heard_as": ["Free"]}]"#)
        }
        #expect(VocabularySuggestionError.unparseable.localizedDescription == "無法解析建議結果")
    }

    @Test func filterRule1DropsTermsAlreadyInVocabularyIgnoringCase() {
        let result = VocabularySuggestionParser.filter(
            [suggestion("ftp"), suggestion("Architecture")], existingTerms: ["FTP"]
        )
        #expect(result.map(\.term) == ["Architecture"])
    }

    @Test func filterRule2EnforcesLengthAndRejectsNewlines() {
        let result = VocabularySuggestionParser.filter(
            [suggestion("   "), suggestion(String(repeating: "a", count: 41)),
             suggestion(String(repeating: "b", count: 40)), suggestion("Line\nBreak"),
             suggestion("  KM  ")],
            existingTerms: []
        )
        #expect(result.map(\.term) == [String(repeating: "b", count: 40), "KM"])
    }

    @Test func filterRule3DedupesWithinReplyIgnoringCase() {
        let result = VocabularySuggestionParser.filter(
            [suggestion("Whisper"), suggestion("WHISPER"), suggestion(" whisper ")], existingTerms: []
        )
        #expect(result.map(\.term) == ["Whisper"])
    }

    @Test func filterRule4CapsAtTwenty() {
        let result = VocabularySuggestionParser.filter(
            (1...25).map { suggestion("Term\($0)") }, existingTerms: []
        )
        #expect(result.count == 20)
        #expect(result.last?.term == "Term20")
    }
}

// MARK: - Request assembly (AC-7)

struct VocabularySuggestionClientTests {
    @Test func openAIRequestCarriesTranscriptAndJSONOnlyInstructions() async throws {
        let transport = CountingTransport { request in
            #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
            let body = try #require(request.httpBody)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["model"] as? String == "gpt-5")
            #expect(json["store"] as? Bool == false)
            #expect((json["instructions"] as? String)?.contains("只回傳 JSON") == true)
            #expect((json["input"] as? String)?.contains("Articature") == true)
            return try ok(request, ["output": [["content": [["type": "output_text", "text": "[]"]]]]])
        }
        let reply = try await OpenAIVocabularySuggestionClient(transport: transport)
            .suggest(transcript: entry.text, apiKey: "secret")
        #expect(reply == "[]")
        #expect(transport.callCount == 1)
    }

    @Test func anthropicRequestCarriesTranscriptAndJSONOnlySystem() async throws {
        let transport = CountingTransport { request in
            #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
            #expect(request.value(forHTTPHeaderField: "x-api-key") == "anthropic-secret")
            #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
            let body = try #require(request.httpBody)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["model"] as? String == "claude-sonnet-4-6")
            #expect((json["system"] as? String)?.contains("只回傳 JSON") == true)
            let messages = try #require(json["messages"] as? [[String: Any]])
            #expect((messages.first?["content"] as? String)?.contains("Articature") == true)
            return try ok(request, ["content": [["type": "text", "text": #"[{"term":"FTP"}]"#]]])
        }
        let reply = try await AnthropicVocabularySuggestionClient(transport: transport)
            .suggest(transcript: entry.text, apiKey: "anthropic-secret")
        #expect(reply == #"[{"term":"FTP"}]"#)
    }

    @Test func networkFailureIsReportedAsAmbiguousWithoutRetry() async {
        let transport = CountingTransport { _ in throw URLError(.timedOut) }
        await #expect(throws: MeetingSummaryClientError.ambiguousOutcome("openai")) {
            try await OpenAIVocabularySuggestionClient(transport: transport)
                .suggest(transcript: "x", apiKey: "secret")
        }
        #expect(transport.callCount == 1)
    }
}

// MARK: - Controller (AC-2, AC-4, AC-5, AC-6)

@MainActor
struct VocabularySuggestionControllerTests {
    private func controller(
        _ transport: CountingTransport, key: String? = "secret"
    ) -> VocabularySuggestionController {
        VocabularySuggestionController(
            clients: [.openAI: OpenAIVocabularySuggestionClient(transport: transport)],
            credentials: { _ in key }
        )
    }

    @Test func loadsSuggestionsAndFiltersExistingTermsIgnoringCase() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.add("km")
        let transport = openAITransport(reply: """
        [{"term": "FTP", "heard_as": ["Free"], "reason": "檔案傳輸"},
         {"term": "KM", "heard_as": [], "reason": "知識管理"},
         {"term": "Architecture", "heard_as": ["Articature"], "reason": "架構"}]
        """)
        let sut = controller(transport)

        await sut.requestSuggestions(
            transcriptionID: entry.id, transcript: entry.text, provider: .openAI, existingTerms: store.terms.map(\.value)
        )

        #expect(sut.status == .loaded)
        #expect(sut.sourceTranscriptionID == entry.id)
        #expect(sut.suggestions.map(\.term) == ["FTP", "Architecture"])
        #expect(sut.suggestions.first?.heardAs == ["Free"])
        #expect(store.terms.map(\.value) == ["km"])
    }

    @Test(arguments: ["這不是 JSON", #"[{"reason": "缺 term"}]"#])
    func unparseableReplyFailsAndLeavesVocabularyUntouched(reply: String) async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.add("VIA")
        let before = store.terms
        let sut = controller(openAITransport(reply: reply))

        await sut.requestSuggestions(transcriptionID: entry.id, transcript: entry.text, provider: .openAI, existingTerms: ["VIA"])

        #expect(sut.status == .failed("無法解析建議結果"))
        #expect(sut.suggestions.isEmpty)
        #expect(store.terms == before)
    }

    @Test func emptyArrayLoadsEmptyAndLeavesVocabularyUntouched() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        try store.add("VIA")
        let before = store.terms
        let sut = controller(openAITransport(reply: "[]"))

        await sut.requestSuggestions(transcriptionID: entry.id, transcript: entry.text, provider: .openAI, existingTerms: ["VIA"])

        #expect(sut.status == .loaded)
        #expect(sut.suggestions.isEmpty)
        #expect(store.terms == before)
    }

    @Test func missingCredentialSendsNoRequest() async {
        let transport = openAITransport(reply: "[]")
        let sut = controller(transport, key: nil)

        await sut.requestSuggestions(transcriptionID: entry.id, transcript: entry.text, provider: .openAI, existingTerms: [])

        #expect(transport.callCount == 0)
        #expect(sut.status == .failed(
            MeetingSummaryClientError.missingCredential("OpenAI").localizedDescription
        ))
    }

    @Test func blankCredentialAlsoSendsNoRequest() async {
        let transport = openAITransport(reply: "[]")
        let sut = controller(transport, key: "   ")

        await sut.requestSuggestions(transcriptionID: entry.id, transcript: entry.text, provider: .openAI, existingTerms: [])

        #expect(transport.callCount == 0)
        guard case .failed = sut.status else { Issue.record("expected failed"); return }
    }

    @Test func usesSelectedProviderOnly() async {
        let openAI = openAITransport(reply: "[]")
        let anthropic = CountingTransport { request in
            try ok(request, ["content": [["type": "text", "text": #"[{"term":"FTP"}]"#]]])
        }
        let sut = VocabularySuggestionController(
            clients: [
                .openAI: OpenAIVocabularySuggestionClient(transport: openAI),
                .anthropic: AnthropicVocabularySuggestionClient(transport: anthropic),
            ],
            credentials: { provider in
                #expect(provider == .anthropic)
                return "anthropic-key"
            }
        )

        await sut.requestSuggestions(transcriptionID: entry.id, transcript: entry.text, provider: .anthropic, existingTerms: [])

        #expect(openAI.callCount == 0)
        #expect(anthropic.callCount == 1)
        #expect(sut.suggestions.map(\.term) == ["FTP"])
    }

    @Test func addPersistsTermAndRemovesItFromCandidates() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sut = controller(openAITransport(reply: #"[{"term":"FTP"},{"term":"KM"}]"#))
        await sut.requestSuggestions(transcriptionID: entry.id, transcript: entry.text, provider: .openAI, existingTerms: [])

        sut.add(try #require(sut.suggestions.first), to: store)

        #expect(store.terms.map(\.value) == ["FTP"])
        #expect(sut.suggestions.map(\.term) == ["KM"])
        #expect(sut.addError == nil)
    }

    @Test func addAllPersistsEveryCandidateAndClearsList() async throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sut = controller(openAITransport(reply: #"[{"term":"FTP"},{"term":"KM"}]"#))
        await sut.requestSuggestions(transcriptionID: entry.id, transcript: entry.text, provider: .openAI, existingTerms: [])

        sut.addAll(to: store)

        #expect(store.terms.map(\.value) == ["FTP", "KM"])
        #expect(sut.suggestions.isEmpty)
    }

    @Test func secondRequestWhileLoadingIsIgnored() async throws {
        let gate = AsyncStream<Void>.makeStream()
        let started = AsyncStream<Void>.makeStream()
        let transport = GatedTransport(started: started.continuation, gate: gate.stream)
        let sut = VocabularySuggestionController(
            clients: [.openAI: OpenAIVocabularySuggestionClient(transport: transport)],
            credentials: { _ in "secret" }
        )
        let otherID = UUID()

        let first = Task {
            await sut.requestSuggestions(
                transcriptionID: entry.id, transcript: entry.text, provider: .openAI, existingTerms: []
            )
        }
        var startedIterator = started.stream.makeAsyncIterator()
        _ = await startedIterator.next()
        #expect(sut.isLoading)

        await sut.requestSuggestions(
            transcriptionID: otherID, transcript: "other", provider: .openAI, existingTerms: []
        )
        #expect(sut.sourceTranscriptionID == entry.id)
        #expect(sut.isLoading)

        gate.continuation.yield()
        await first.value
        #expect(transport.callCount == 1)
        #expect(sut.status == .loaded)
        #expect(sut.sourceTranscriptionID == entry.id)
        #expect(sut.suggestions.map(\.term) == ["FTP"])
    }

    @Test func storeWriteFailureKeepsCandidatesAndShowsError() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // A regular file where the vocabulary directory should be makes every write fail.
        let blocker = directory.appendingPathComponent("blocker")
        try Data().write(to: blocker)
        let store = VocabularyStore(fileURL: blocker.appendingPathComponent("vocabulary.json"))
        let sut = controller(openAITransport(reply: #"[{"term":"FTP"},{"term":"KM"}]"#))
        await sut.requestSuggestions(transcriptionID: entry.id, transcript: entry.text, provider: .openAI, existingTerms: [])

        sut.add(try #require(sut.suggestions.first), to: store)
        #expect(sut.suggestions.map(\.term) == ["FTP", "KM"])
        #expect(sut.addError?.contains("加入詞彙失敗") == true)

        sut.addAll(to: store)
        #expect(sut.suggestions.map(\.term) == ["FTP", "KM"])
        #expect(sut.addError != nil)
        #expect(store.terms.isEmpty)
    }
}
