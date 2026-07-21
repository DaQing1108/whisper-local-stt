import Foundation
import Testing
@testable import WhisperApp

/// Routes each request by HTTP method + path so a single fake can serve the distinct
/// create/list/append/delete calls `publish()` now makes, unlike the old fixed-response fake.
private actor ScriptedNotionTransport: NotionHTTPTransport {
    struct Response { let statusCode: Int; let body: Data }

    private(set) var requests: [URLRequest] = []
    private let handler: @Sendable (URLRequest) throws -> Response

    init(handler: @escaping @Sendable (URLRequest) throws -> Response) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let result = try handler(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: result.statusCode, httpVersion: nil, headerFields: nil
        )!
        return (result.body, response)
    }

    func captured() -> [URLRequest] { requests }

    static func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }
}

private struct FailingNotionTransport: NotionHTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.timedOut)
    }
}

struct NotionClientTests {
    @Test
    func createsChildPageUsingCurrentHeadersWithoutExposingTokenInBody() async throws {
        let transport = ScriptedNotionTransport { _ in
            .init(statusCode: 200, body: ScriptedNotionTransport.json(["id": "new-page-id"]))
        }
        let client = NotionClient(transport: transport)
        let entry = TranscriptionHistoryEntry(
            id: UUID(), completedAt: Date(timeIntervalSince1970: 0),
            audioPath: "/tmp/audio.wav", model: "base", language: "zh", text: "逐字稿"
        )

        let pageID = try await client.publish(
            entry, parentPageID: "0123456789abcdef0123456789abcdef",
            existingChildPageID: nil, token: "secret_token"
        )

        #expect(pageID == "new-page-id")
        let request = try #require(await transport.captured().first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString.hasSuffix("/v1/pages") == true)
        #expect(request.value(forHTTPHeaderField: "Notion-Version") == "2026-03-11")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret_token")
        #expect(!String(data: try #require(request.httpBody), encoding: .utf8)!.contains("secret_token"))
    }

    @Test
    func createdPageIncludesSummaryAndSourceAsSeparateSections() async throws {
        let transport = ScriptedNotionTransport { _ in
            .init(statusCode: 200, body: ScriptedNotionTransport.json(["id": "new-page-id"]))
        }
        let client = NotionClient(transport: transport)
        let entry = TranscriptionHistoryEntry(
            audioPath: "/tmp/audio.wav", model: "base", language: "zh", text: "source transcript"
        )
        let summary = MeetingSummary(
            transcriptionID: entry.id, meetingTitle: "產品週會",
            generatedText: "generated", editedText: "edited summary",
            provider: "openai", status: .completed
        )

        _ = try await client.publish(
            entry, summary: summary, parentPageID: "0123456789abcdef0123456789abcdef",
            existingChildPageID: nil, token: "token"
        )

        let request = try #require(await transport.captured().first)
        let body = String(data: try #require(request.httpBody), encoding: .utf8)!
        #expect(body.contains("產品週會"))
        #expect(body.contains("edited summary"))
        #expect(body.contains("Source transcript"))
        #expect(body.contains("source transcript"))
    }

    @Test
    func rejectsInvalidParentPageIDBeforeNetworkAndReportsHTTPFailure() async throws {
        let transport = ScriptedNotionTransport { _ in .init(statusCode: 403, body: Data()) }
        let client = NotionClient(transport: transport)
        let entry = TranscriptionHistoryEntry(
            id: UUID(), completedAt: Date(), audioPath: "/tmp/a.wav",
            model: "base", language: nil, text: "text"
        )

        await #expect(throws: NotionClientError.invalidPageID) {
            try await client.publish(entry, parentPageID: "../escape", existingChildPageID: nil, token: "token")
        }
        #expect(await transport.captured().isEmpty)
        await #expect(throws: NotionClientError.httpStatus(403)) {
            try await client.publish(
                entry, parentPageID: "0123456789abcdef0123456789abcdef",
                existingChildPageID: nil, token: "token"
            )
        }
    }

    @Test
    func rejectsOversizedTranscriptBeforeAnyNetworkCall() async {
        let transport = ScriptedNotionTransport { _ in
            .init(statusCode: 200, body: ScriptedNotionTransport.json(["id": "x"]))
        }
        let client = NotionClient(transport: transport)
        let entry = TranscriptionHistoryEntry(
            id: UUID(), completedAt: Date(), audioPath: "/tmp/a.wav",
            model: "base", language: nil, text: String(repeating: "字", count: 198_001)
        )

        await #expect(throws: NotionClientError.contentTooLarge) {
            try await client.publish(
                entry, parentPageID: "0123456789abcdef0123456789abcdef",
                existingChildPageID: nil, token: "token"
            )
        }
        #expect(await transport.captured().isEmpty)
    }

    @Test
    func transportFailureDuringCreateIsReportedAsAmbiguous() async {
        let client = NotionClient(transport: FailingNotionTransport())
        let entry = TranscriptionHistoryEntry(
            id: UUID(), completedAt: Date(), audioPath: "/tmp/a.wav",
            model: "base", language: nil, text: "text"
        )

        await #expect(throws: NotionClientError.ambiguousOutcome) {
            try await client.publish(
                entry, parentPageID: "0123456789abcdef0123456789abcdef",
                existingChildPageID: nil, token: "token"
            )
        }
    }

    @Test
    func serverFailureDuringCreateIsAmbiguousBecauseItMayHaveCommitted() async {
        let transport = ScriptedNotionTransport { _ in .init(statusCode: 502, body: Data()) }
        let client = NotionClient(transport: transport)
        let entry = TranscriptionHistoryEntry(
            id: UUID(), completedAt: Date(), audioPath: "/tmp/a.wav",
            model: "base", language: nil, text: "text"
        )

        await #expect(throws: NotionClientError.ambiguousOutcome) {
            try await client.publish(
                entry, parentPageID: "0123456789abcdef0123456789abcdef",
                existingChildPageID: nil, token: "token"
            )
        }
    }

    @Test
    func republishingToExistingChildPageWritesNewContentBeforeDeletingOld() async throws {
        let transport = ScriptedNotionTransport { request in
            switch request.httpMethod {
            case "GET":
                return .init(statusCode: 200, body: ScriptedNotionTransport.json([
                    "results": [["id": "old-block-1"], ["id": "old-block-2"]], "has_more": false,
                ]))
            case "PATCH", "DELETE":
                return .init(statusCode: 200, body: Data("{}".utf8))
            default:
                Issue.record("unexpected \(request.httpMethod ?? "?") to \(request.url?.path ?? "")")
                return .init(statusCode: 500, body: Data())
            }
        }
        let client = NotionClient(transport: transport)
        let entry = TranscriptionHistoryEntry(
            audioPath: "/tmp/a.wav", model: "base", language: nil, text: "updated text"
        )

        let pageID = try await client.publish(
            entry, parentPageID: "0123456789abcdef0123456789abcdef",
            existingChildPageID: "existing-page-id", token: "token"
        )

        #expect(pageID == "existing-page-id")
        let requests = await transport.captured()
        #expect(!requests.contains { $0.url?.absoluteString.hasSuffix("/v1/pages") == true })
        let methods = requests.map { $0.httpMethod }
        #expect(methods == ["GET", "PATCH", "DELETE", "DELETE"])
        let deletedPaths = requests.filter { $0.httpMethod == "DELETE" }.map { $0.url!.lastPathComponent }
        #expect(Set(deletedPaths) == ["old-block-1", "old-block-2"])
    }

    @Test
    func listsAllPagesOfExistingBlocksBeforeDeletingAnyOfThem() async throws {
        let transport = ScriptedNotionTransport { request in
            switch request.httpMethod {
            case "GET":
                let cursor = request.url?.query?.contains("start_cursor=page-2") == true
                return .init(statusCode: 200, body: ScriptedNotionTransport.json(
                    cursor
                        ? ["results": [["id": "block-page-2"]], "has_more": false]
                        : ["results": [["id": "block-page-1"]], "has_more": true, "next_cursor": "page-2"]
                ))
            case "PATCH", "DELETE":
                return .init(statusCode: 200, body: Data("{}".utf8))
            default:
                Issue.record("unexpected \(request.httpMethod ?? "?")")
                return .init(statusCode: 500, body: Data())
            }
        }
        let client = NotionClient(transport: transport)
        let entry = TranscriptionHistoryEntry(
            audioPath: "/tmp/a.wav", model: "base", language: nil, text: "text"
        )

        _ = try await client.publish(
            entry, parentPageID: "0123456789abcdef0123456789abcdef",
            existingChildPageID: "existing-page-id", token: "token"
        )

        let requests = await transport.captured()
        #expect(requests.filter { $0.httpMethod == "GET" }.count == 2)
        let deletedPaths = Set(requests.filter { $0.httpMethod == "DELETE" }.map { $0.url!.lastPathComponent })
        #expect(deletedPaths == ["block-page-1", "block-page-2"])
    }

    @Test
    func listingBailsOutInsteadOfLoopingForeverOnAnEndlessHasMore() async {
        let transport = ScriptedNotionTransport { request in
            guard request.httpMethod == "GET" else {
                return .init(statusCode: 200, body: Data("{}".utf8))
            }
            // Always claims more pages exist, with a cursor value that never terminates —
            // exercises the maximumListPages bound rather than the pagination happy path.
            return .init(statusCode: 200, body: ScriptedNotionTransport.json([
                "results": [["id": "block"]], "has_more": true, "next_cursor": "same-cursor-forever",
            ]))
        }
        let client = NotionClient(transport: transport)
        let entry = TranscriptionHistoryEntry(
            audioPath: "/tmp/a.wav", model: "base", language: nil, text: "text"
        )

        await #expect(throws: NotionClientError.invalidResponse) {
            try await client.publish(
                entry, parentPageID: "0123456789abcdef0123456789abcdef",
                existingChildPageID: "existing-page-id", token: "token"
            )
        }
        let getCount = await transport.captured().filter { $0.httpMethod == "GET" }.count
        #expect(getCount == 500)
    }

    @Test
    func listingRejectsAResultBlockMissingAValidID() async {
        let transport = ScriptedNotionTransport { request in
            guard request.httpMethod == "GET" else {
                return .init(statusCode: 200, body: Data("{}".utf8))
            }
            return .init(statusCode: 200, body: ScriptedNotionTransport.json([
                "results": [["id": "good-block"], ["object": "block"]], "has_more": false,
            ]))
        }
        let client = NotionClient(transport: transport)
        let entry = TranscriptionHistoryEntry(
            audioPath: "/tmp/a.wav", model: "base", language: nil, text: "text"
        )

        await #expect(throws: NotionClientError.invalidResponse) {
            try await client.publish(
                entry, parentPageID: "0123456789abcdef0123456789abcdef",
                existingChildPageID: "existing-page-id", token: "token"
            )
        }
        #expect(!(await transport.captured().contains { $0.httpMethod == "DELETE" }))
    }

    @Test
    func appendFailureDuringUpdateLeavesOldContentUntouched() async {
        let transport = ScriptedNotionTransport { request in
            switch request.httpMethod {
            case "GET":
                return .init(statusCode: 200, body: ScriptedNotionTransport.json([
                    "results": [["id": "old-block-1"]], "has_more": false,
                ]))
            case "PATCH":
                return .init(statusCode: 500, body: Data())
            default:
                Issue.record("unexpected \(request.httpMethod ?? "?")")
                return .init(statusCode: 500, body: Data())
            }
        }
        let client = NotionClient(transport: transport)
        let entry = TranscriptionHistoryEntry(
            audioPath: "/tmp/a.wav", model: "base", language: nil, text: "text"
        )

        await #expect(throws: NotionClientError.ambiguousOutcome) {
            try await client.publish(
                entry, parentPageID: "0123456789abcdef0123456789abcdef",
                existingChildPageID: "existing-page-id", token: "token"
            )
        }
        let requests = await transport.captured()
        #expect(!requests.contains { $0.httpMethod == "DELETE" })
    }

    @Test
    func successfulRepublishSweepsUpAnyLeftoverBlocksFromAPriorPartialFailure() async throws {
        // Simulates the recovery call after a prior attempt's delete step failed partway:
        // the list response reflects whatever is actually still on the page (a mix of
        // genuinely-old blocks and a stale block from the prior attempt's own append).
        let transport = ScriptedNotionTransport { request in
            switch request.httpMethod {
            case "GET":
                return .init(statusCode: 200, body: ScriptedNotionTransport.json([
                    "results": [
                        ["id": "leftover-from-prior-attempt"], ["id": "genuinely-old-block"],
                    ], "has_more": false,
                ]))
            case "PATCH", "DELETE":
                return .init(statusCode: 200, body: Data("{}".utf8))
            default:
                Issue.record("unexpected \(request.httpMethod ?? "?")")
                return .init(statusCode: 500, body: Data())
            }
        }
        let client = NotionClient(transport: transport)
        let entry = TranscriptionHistoryEntry(
            audioPath: "/tmp/a.wav", model: "base", language: nil, text: "latest text"
        )

        let pageID = try await client.publish(
            entry, parentPageID: "0123456789abcdef0123456789abcdef",
            existingChildPageID: "existing-page-id", token: "token"
        )

        #expect(pageID == "existing-page-id")
        let deletedPaths = Set(
            await transport.captured().filter { $0.httpMethod == "DELETE" }.map { $0.url!.lastPathComponent }
        )
        #expect(deletedPaths == ["leftover-from-prior-attempt", "genuinely-old-block"])
    }

    @Test(arguments: [
        NotionClientError.missingToken,
        .invalidPageID,
        .contentTooLarge,
        .httpStatus(400),
        .httpStatus(404),
    ])
    func errorsThatNeverReachOrAreCleanlyRejectedByNotionClearTheAmbiguousLock(_ error: NotionClientError) {
        #expect(error.clearsAmbiguousLock)
    }

    @Test(arguments: [NotionClientError.ambiguousOutcome, .invalidResponse])
    func errorsWithUncertainDeliveryKeepTheAmbiguousLock(_ error: NotionClientError) {
        #expect(!error.clearsAmbiguousLock)
    }
}
