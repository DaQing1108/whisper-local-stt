import Foundation

enum NotionClientError: Error, Equatable {
    case invalidPageID
    case missingToken
    case invalidResponse
    case httpStatus(Int)
    case contentTooLarge
    case ambiguousOutcome
}

protocol NotionHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionNotionTransport: NotionHTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NotionClientError.invalidResponse }
        return (data, http)
    }
}

struct NotionClient: Sendable {
    private let transport: any NotionHTTPTransport
    private let endpoint = URL(string: "https://api.notion.com/v1/blocks/")!

    init(transport: any NotionHTTPTransport = URLSessionNotionTransport()) {
        self.transport = transport
    }

    func append(
        _ entry: TranscriptionHistoryEntry,
        summary: MeetingSummary? = nil,
        pageID: String,
        token: String
    ) async throws {
        let normalizedID = pageID.replacingOccurrences(of: "-", with: "").lowercased()
        guard normalizedID.count == 32,
              normalizedID.unicodeScalars.allSatisfy(CharacterSet(charactersIn: "0123456789abcdef").contains)
        else { throw NotionClientError.invalidPageID }
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NotionClientError.missingToken
        }

        let blocks = makeBlocks(entry, summary: summary)
        // One request avoids ambiguous partial success and duplicate blocks on retry.
        guard blocks.count <= 100 else { throw NotionClientError.contentTooLarge }
        var request = URLRequest(url: endpoint
            .appendingPathComponent(normalizedID)
            .appendingPathComponent("children"))
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2026-03-11", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["children": blocks])
        let response: HTTPURLResponse
        do {
            (_, response) = try await transport.send(request)
        } catch {
            throw NotionClientError.ambiguousOutcome
        }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 408 || response.statusCode == 409
                || response.statusCode == 429 || response.statusCode >= 500 {
                throw NotionClientError.ambiguousOutcome
            }
            throw NotionClientError.httpStatus(response.statusCode)
        }
    }

    private func makeBlocks(
        _ entry: TranscriptionHistoryEntry, summary: MeetingSummary?
    ) -> [[String: Any]] {
        var blocks = [block(type: "heading_2", text: summary?.meetingTitle ?? "Whisper transcription")]
        blocks.append(block(
            type: "paragraph",
            text: "Model: \(entry.model) · Language: \(entry.language ?? "auto") · \(entry.completedAt.formatted())"
        ))
        if let summary, !summary.effectiveText.isEmpty {
            blocks.append(block(type: "heading_3", text: "AI meeting summary"))
            for chunk in chunks(summary.effectiveText, maximumCharacters: 2_000) {
                blocks.append(block(type: "paragraph", text: chunk))
            }
        }
        blocks.append(block(type: "heading_3", text: "Source transcript"))
        for chunk in chunks(entry.text, maximumCharacters: 2_000) {
            blocks.append(block(type: "paragraph", text: chunk))
        }
        return blocks
    }

    private func block(type: String, text: String) -> [String: Any] {
        [
            "object": "block",
            "type": type,
            type: ["rich_text": [["type": "text", "text": ["content": text]]]],
        ]
    }

    private func chunks(_ text: String, maximumCharacters: Int) -> [String] {
        guard !text.isEmpty else { return [""] }
        var result: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: maximumCharacters, limitedBy: text.endIndex) ?? text.endIndex
            result.append(String(text[start..<end]))
            start = end
        }
        return result
    }
}
