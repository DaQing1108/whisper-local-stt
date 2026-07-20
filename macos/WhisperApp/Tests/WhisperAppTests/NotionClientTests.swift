import Foundation
import Testing
@testable import WhisperApp

private actor FakeNotionTransport: NotionHTTPTransport {
    private(set) var requests: [URLRequest] = []
    let statusCode: Int
    init(statusCode: Int = 200) { self.statusCode = statusCode }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: statusCode,
            httpVersion: nil, headerFields: nil
        )!
        return (Data("{}".utf8), response)
    }
    func captured() -> [URLRequest] { requests }
}

private struct FailingNotionTransport: NotionHTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.timedOut)
    }
}

struct NotionClientTests {
    @Test
    func appendsHistoryUsingCurrentHeadersWithoutExposingTokenInBody() async throws {
        let transport = FakeNotionTransport()
        let client = NotionClient(transport: transport)
        let entry = TranscriptionHistoryEntry(
            id: UUID(), completedAt: Date(timeIntervalSince1970: 0),
            audioPath: "/tmp/audio.wav", model: "base", language: "zh", text: "逐字稿"
        )

        try await client.append(entry, pageID: "0123456789abcdef0123456789abcdef", token: "secret_token")

        let request = try #require(await transport.captured().first)
        #expect(request.httpMethod == "PATCH")
        #expect(request.value(forHTTPHeaderField: "Notion-Version") == "2026-03-11")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret_token")
        #expect(!String(data: try #require(request.httpBody), encoding: .utf8)!.contains("secret_token"))
        #expect(request.url?.absoluteString.contains("0123456789abcdef0123456789abcdef/children") == true)
    }

    @Test
    func appendExistingPageIncludesSummaryAndSourceAsSeparateSections() async throws {
        let transport = FakeNotionTransport()
        let client = NotionClient(transport: transport)
        let entry = TranscriptionHistoryEntry(
            audioPath: "/tmp/audio.wav", model: "base", language: "zh", text: "source transcript"
        )
        let summary = MeetingSummary(
            transcriptionID: entry.id, meetingTitle: "產品週會",
            generatedText: "generated", editedText: "edited summary",
            provider: "openai", status: .completed
        )

        try await client.append(
            entry, summary: summary,
            pageID: "0123456789abcdef0123456789abcdef", token: "token"
        )

        let request = try #require(await transport.captured().first)
        let body = String(data: try #require(request.httpBody), encoding: .utf8)!
        #expect(body.contains("產品週會"))
        #expect(body.contains("edited summary"))
        #expect(body.contains("Source transcript"))
        #expect(body.contains("source transcript"))
    }

    @Test
    func rejectsInvalidPageIDBeforeNetworkAndReportsHTTPFailure() async throws {
        let transport = FakeNotionTransport(statusCode: 403)
        let client = NotionClient(transport: transport)
        let entry = TranscriptionHistoryEntry(
            id: UUID(), completedAt: Date(), audioPath: "/tmp/a.wav",
            model: "base", language: nil, text: "text"
        )

        await #expect(throws: NotionClientError.invalidPageID) {
            try await client.append(entry, pageID: "../escape", token: "token")
        }
        #expect(await transport.captured().isEmpty)
        await #expect(throws: NotionClientError.httpStatus(403)) {
            try await client.append(entry, pageID: "0123456789abcdef0123456789abcdef", token: "token")
        }
    }

    @Test
    func rejectsOversizedTranscriptBeforeAnyPartialAppend() async {
        let transport = FakeNotionTransport()
        let client = NotionClient(transport: transport)
        let entry = TranscriptionHistoryEntry(
            id: UUID(), completedAt: Date(), audioPath: "/tmp/a.wav",
            model: "base", language: nil, text: String(repeating: "字", count: 198_001)
        )

        await #expect(throws: NotionClientError.contentTooLarge) {
            try await client.append(entry, pageID: "0123456789abcdef0123456789abcdef", token: "token")
        }
        #expect(await transport.captured().isEmpty)
    }

    @Test
    func transportFailureIsReportedAsAmbiguousInsteadOfSafeToRetry() async {
        let client = NotionClient(transport: FailingNotionTransport())
        let entry = TranscriptionHistoryEntry(
            id: UUID(), completedAt: Date(), audioPath: "/tmp/a.wav",
            model: "base", language: nil, text: "text"
        )

        await #expect(throws: NotionClientError.ambiguousOutcome) {
            try await client.append(entry, pageID: "0123456789abcdef0123456789abcdef", token: "token")
        }
    }

    @Test
    func serverFailureIsAmbiguousBecauseAppendMayHaveCommitted() async {
        let client = NotionClient(transport: FakeNotionTransport(statusCode: 502))
        let entry = TranscriptionHistoryEntry(
            id: UUID(), completedAt: Date(), audioPath: "/tmp/a.wav",
            model: "base", language: nil, text: "text"
        )

        await #expect(throws: NotionClientError.ambiguousOutcome) {
            try await client.append(entry, pageID: "0123456789abcdef0123456789abcdef", token: "token")
        }
    }
}
