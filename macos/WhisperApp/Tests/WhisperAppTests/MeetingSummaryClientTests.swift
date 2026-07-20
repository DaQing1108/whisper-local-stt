import Foundation
import Testing
@testable import WhisperApp

private struct SummaryTransportStub: MeetingSummaryHTTPTransport {
    let handler: @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { try handler(request) }
}

@MainActor
struct MeetingSummaryClientTests {
    @Test func clientErrorsProvideActionableLocalizedDescriptions() {
        #expect(MeetingSummaryClientError.missingCredential("OpenAI").localizedDescription.contains("OpenAI API key"))
        #expect(MeetingSummaryClientError.missingCredential("OpenAI").localizedDescription.contains("進階設定與整合"))
        #expect(MeetingSummaryClientError.httpStatus("OpenAI", 401).localizedDescription.contains("401"))
        #expect(MeetingSummaryClientError.httpStatus("OpenAI", 429).localizedDescription.contains("429"))
        #expect(MeetingSummaryClientError.ambiguousOutcome("OpenAI").localizedDescription.contains("網路"))
    }

    @Test func anthropicClientBuildsMessagesRequestAndExtractsText() async throws {
        let transport = SummaryTransportStub { request in
            #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
            #expect(request.value(forHTTPHeaderField: "x-api-key") == "anthropic-secret")
            #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
            let body = try #require(request.httpBody)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["model"] as? String == "claude-sonnet-4-6")
            #expect(json["max_tokens"] as? Int == 2_048)
            let messages = try #require(json["messages"] as? [[String: Any]])
            #expect((messages.first?["content"] as? String)?.contains("逐字稿") == true)
            let data = try JSONSerialization.data(withJSONObject: [
                "content": [["type": "text", "text": "## 摘要\nClaude 完成"]]
            ])
            return (data, HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!)
        }

        let text = try await AnthropicMeetingSummaryClient(transport: transport).generate(
            transcript: "逐字稿", apiKey: "anthropic-secret"
        )
        #expect(text == "## 摘要\nClaude 完成")
    }

    @Test func anthropicClientRejectsTruncatedOutput() async throws {
        let transport = SummaryTransportStub { request in
            let data = try JSONSerialization.data(withJSONObject: [
                "stop_reason": "max_tokens",
                "content": [["type": "text", "text": "incomplete"]],
            ])
            return (data, HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!)
        }

        await #expect(throws: MeetingSummaryClientError.truncatedOutput("Anthropic Claude")) {
            try await AnthropicMeetingSummaryClient(transport: transport).generate(
                transcript: "long transcript", apiKey: "anthropic-secret"
            )
        }
    }

    @Test func responsesClientDisablesStorageAndExtractsOutputText() async throws {
        let transport = SummaryTransportStub { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
            let body = try #require(request.httpBody)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["store"] as? Bool == false)
            #expect((json["input"] as? String)?.contains("逐字稿") == true)
            let data = try JSONSerialization.data(withJSONObject: [
                "output": [["content": [["type": "output_text", "text": "## 摘要\n完成"]]]]
            ])
            return (data, HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!)
        }

        let text = try await OpenAIMeetingSummaryClient(transport: transport).generate(
            transcript: "逐字稿", apiKey: "secret"
        )
        #expect(text == "## 摘要\n完成")
    }

    @Test func controllerFailureIsPersistedWithoutChangingTranscript() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingSummaryStore(fileURL: directory.appendingPathComponent("summary.json"))
        let entry = TranscriptionHistoryEntry(
            audioPath: "/tmp/a.wav", model: "base", language: "zh", text: "source remains"
        )
        let controller = MeetingSummaryController(
            store: store,
            generators: [.openAI: FailingGenerator()],
            credentials: { _ in "test-key" }
        )

        await controller.generate(for: entry, title: "會議")

        #expect(entry.text == "source remains")
        #expect(store.summary(for: entry.id)?.status == .failed)
        #expect(controller.activeTranscriptionID == nil)
    }

    @Test func missingCredentialIsReportedWithSetupInstructions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingSummaryStore(fileURL: directory.appendingPathComponent("summary.json"))
        let entry = TranscriptionHistoryEntry(
            audioPath: "/tmp/a.wav", model: "base", language: "zh", text: "source"
        )
        let controller = MeetingSummaryController(
            store: store,
            generators: [.openAI: FailingGenerator()],
            credentials: { _ in nil }
        )

        await controller.generate(for: entry, title: "會議")

        let message = try #require(controller.lastError)
        #expect(message.contains("OpenAI API key"))
        #expect(message.contains("進階設定與整合"))
        #expect(store.summary(for: entry.id)?.errorMessage == message)
    }

    @Test func controllerUsesSelectedAnthropicProviderAndCredential() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingSummaryStore(fileURL: directory.appendingPathComponent("summary.json"))
        let entry = TranscriptionHistoryEntry(
            audioPath: "/tmp/a.wav", model: "base", language: "zh", text: "source"
        )
        let controller = MeetingSummaryController(
            store: store,
            generators: [.anthropic: SuccessfulGenerator(providerName: "Anthropic Claude")],
            credentials: { provider in
                #expect(provider == .anthropic)
                return "anthropic-key"
            }
        )

        await controller.generate(for: entry, title: "會議", provider: .anthropic)

        let summary = try #require(store.summary(for: entry.id))
        #expect(summary.status == .completed)
        #expect(summary.provider == "Anthropic Claude")
        #expect(summary.generatedText == "generated")
    }

    private struct FailingGenerator: MeetingSummaryGenerating {
        let providerName = "test"
        func generate(transcript: String, apiKey: String) async throws -> String {
            throw MeetingSummaryClientError.httpStatus("test", 503)
        }
    }

    private struct SuccessfulGenerator: MeetingSummaryGenerating {
        let providerName: String
        func generate(transcript: String, apiKey: String) async throws -> String {
            #expect(apiKey == "anthropic-key")
            return "generated"
        }
    }
}
