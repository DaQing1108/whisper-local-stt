import Foundation

enum NotionClientError: Error, Equatable {
    case invalidPageID
    case missingToken
    case invalidResponse
    case httpStatus(Int)
    case contentTooLarge
    case ambiguousOutcome

    /// Whether this error guarantees the append request never reached Notion (or reached it and
    /// was cleanly rejected), so an optimistic ambiguous-outcome lock set before the request is
    /// safe to clear immediately. `.ambiguousOutcome` and `.invalidResponse` are excluded: the
    /// former is ambiguous by definition, and the latter means the network layer returned
    /// something after the request was already sent, so we can't be certain Notion never
    /// processed it.
    var clearsAmbiguousLock: Bool {
        switch self {
        case .missingToken, .invalidPageID, .contentTooLarge, .httpStatus:
            true
        case .invalidResponse, .ambiguousOutcome:
            false
        }
    }
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
    private let apiBase = URL(string: "https://api.notion.com/v1")!
    private static let notionVersion = "2026-03-11"

    init(transport: any NotionHTTPTransport = URLSessionNotionTransport()) {
        self.transport = transport
    }

    /// Creates a dedicated child page under `parentPageID` on first publish, or updates that
    /// same child page on republish. On update, new content is written before old content is
    /// deleted (the reverse of the Python production app's order) so a mid-update failure
    /// never leaves the page empty — worst case is old and new content briefly coexisting,
    /// which self-heals on the next successful publish. Returns the child page id to persist.
    func publish(
        _ entry: TranscriptionHistoryEntry,
        summary: MeetingSummary? = nil,
        parentPageID: String,
        existingChildPageID: String?,
        token: String
    ) async throws -> String {
        let normalizedParent = try normalize(parentPageID)
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NotionClientError.missingToken
        }
        let blocks = makeBlocks(entry, summary: summary)
        // One request avoids ambiguous partial success and duplicate blocks on retry.
        guard blocks.count <= 100 else { throw NotionClientError.contentTooLarge }

        if let existingChildPageID, !existingChildPageID.isEmpty {
            try await updateChildPage(existingChildPageID, blocks: blocks, token: token)
            return existingChildPageID
        }
        return try await createChildPage(
            parent: normalizedParent,
            title: summary?.meetingTitle ?? "Whisper transcription",
            blocks: blocks, token: token
        )
    }

    private func normalize(_ pageID: String) throws -> String {
        let normalizedID = pageID.replacingOccurrences(of: "-", with: "").lowercased()
        guard normalizedID.count == 32,
              normalizedID.unicodeScalars.allSatisfy(CharacterSet(charactersIn: "0123456789abcdef").contains)
        else { throw NotionClientError.invalidPageID }
        return normalizedID
    }

    private func createChildPage(
        parent: String, title: String, blocks: [[String: Any]], token: String
    ) async throws -> String {
        var request = URLRequest(url: apiBase.appendingPathComponent("pages"))
        request.httpMethod = "POST"
        applyHeaders(&request, token: token)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "parent": ["page_id": parent],
            "properties": ["title": ["title": [["type": "text", "text": ["content": title]]]]],
            "children": blocks,
        ])
        let data = try await sendExpectingSuccess(request)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String else {
            throw NotionClientError.invalidResponse
        }
        return id
    }

    private func updateChildPage(_ pageID: String, blocks: [[String: Any]], token: String) async throws {
        let staleBlockIDs = try await listChildBlockIDs(pageID, token: token)
        try await appendBlocks(pageID, blocks: blocks, token: token)
        for blockID in staleBlockIDs {
            try await deleteBlock(blockID, token: token)
        }
    }

    /// Bounded to guard against a malformed/looping next_cursor causing an unbounded request
    /// spin — 500 pages (50,000 blocks) is far beyond anything a real meeting note would have.
    private static let maximumListPages = 500

    private func listChildBlockIDs(_ pageID: String, token: String) async throws -> [String] {
        var ids: [String] = []
        var cursor: String?
        var pageCount = 0
        repeat {
            pageCount += 1
            guard pageCount <= Self.maximumListPages else { throw NotionClientError.invalidResponse }
            var components = URLComponents(
                url: apiBase.appendingPathComponent("blocks/\(pageID)/children"),
                resolvingAgainstBaseURL: false
            )!
            var items = [URLQueryItem(name: "page_size", value: "100")]
            if let cursor { items.append(URLQueryItem(name: "start_cursor", value: cursor)) }
            components.queryItems = items
            var request = URLRequest(url: components.url!)
            request.httpMethod = "GET"
            applyHeaders(&request, token: token)
            let data = try await sendExpectingSuccess(request)
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = object["results"] as? [[String: Any]] else {
                throw NotionClientError.invalidResponse
            }
            guard results.allSatisfy({ $0["id"] is String }) else {
                throw NotionClientError.invalidResponse
            }
            ids.append(contentsOf: results.compactMap { $0["id"] as? String })
            cursor = (object["has_more"] as? Bool == true) ? object["next_cursor"] as? String : nil
        } while cursor != nil
        return ids
    }

    private func appendBlocks(_ pageID: String, blocks: [[String: Any]], token: String) async throws {
        var request = URLRequest(url: apiBase.appendingPathComponent("blocks/\(pageID)/children"))
        request.httpMethod = "PATCH"
        applyHeaders(&request, token: token)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["children": blocks])
        _ = try await sendExpectingSuccess(request)
    }

    private func deleteBlock(_ blockID: String, token: String) async throws {
        var request = URLRequest(url: apiBase.appendingPathComponent("blocks/\(blockID)"))
        request.httpMethod = "DELETE"
        applyHeaders(&request, token: token)
        _ = try await sendExpectingSuccess(request)
    }

    private func applyHeaders(_ request: inout URLRequest, token: String) {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.notionVersion, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }

    private func sendExpectingSuccess(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
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
        return data
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
