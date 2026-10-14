import Foundation

struct VocabularySuggestion: Identifiable, Equatable, Sendable {
    let term: String
    let heardAs: [String]
    let reason: String

    var id: String { term.lowercased() }
}

enum VocabularySuggestionError: Error, Equatable {
    case unparseable
}

extension VocabularySuggestionError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unparseable: return "無法解析建議結果"
        }
    }
}

/// Sends a transcript to the configured LLM provider and returns its raw text reply.
/// Parsing and filtering happen on the app side (`VocabularySuggestionParser`),
/// so a misbehaving model can never write vocabulary on its own.
protocol VocabularySuggesting: Sendable {
    var providerName: String { get }
    func suggest(transcript: String, apiKey: String) async throws -> String
}

enum VocabularySuggestionPrompt {
    static let instructions = """
    你是語音辨識詞彙顧問。逐字稿由 Whisper 自動轉錄，可能把專有名詞、產品名、英文縮寫或中英混雜詞誤聽成發音相近的字。
    請找出值得加入辨識詞彙表的正確詞，只能依逐字稿內容推斷，不得虛構。
    只回傳 JSON，不要任何其他文字或 Markdown。格式為陣列：
    [{"term": "正確詞", "heard_as": ["逐字稿中的誤聽寫法"], "reason": "簡短理由"}]
    沒有建議時回傳 []。最多 20 筆。
    """

    static func input(for transcript: String) -> String {
        "請只根據以下逐字稿列出建議詞彙：\n\n\(transcript)"
    }
}

struct OpenAIVocabularySuggestionClient: VocabularySuggesting {
    let providerName = "openai"
    private let transport: any MeetingSummaryHTTPTransport
    private let endpoint = URL(string: "https://api.openai.com/v1/responses")!
    private let model: String

    init(
        transport: any MeetingSummaryHTTPTransport = URLSessionMeetingSummaryTransport(),
        model: String = "gpt-5"
    ) {
        self.transport = transport
        self.model = model
    }

    func suggest(transcript: String, apiKey: String) async throws -> String {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MeetingSummaryClientError.missingCredential(providerName)
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 90
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "store": false,
            "instructions": VocabularySuggestionPrompt.instructions,
            "input": VocabularySuggestionPrompt.input(for: transcript),
        ])
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport.send(request) }
        catch { throw MeetingSummaryClientError.ambiguousOutcome(providerName) }
        guard (200..<300).contains(response.statusCode) else {
            throw MeetingSummaryClientError.httpStatus(providerName, response.statusCode)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = root["output"] as? [[String: Any]] else {
            throw MeetingSummaryClientError.invalidResponse(providerName)
        }
        let text = output.compactMap { $0["content"] as? [[String: Any]] }.flatMap { $0 }
            .filter { ($0["type"] as? String) == "output_text" }
            .compactMap { $0["text"] as? String }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw MeetingSummaryClientError.emptyOutput(providerName) }
        return text
    }
}

struct AnthropicVocabularySuggestionClient: VocabularySuggesting {
    let providerName = "Anthropic Claude"
    private let transport: any MeetingSummaryHTTPTransport
    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let model: String

    init(
        transport: any MeetingSummaryHTTPTransport = URLSessionMeetingSummaryTransport(),
        model: String = "claude-sonnet-4-6"
    ) {
        self.transport = transport
        self.model = model
    }

    func suggest(transcript: String, apiKey: String) async throws -> String {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MeetingSummaryClientError.missingCredential(providerName)
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 90
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "max_tokens": 2_048,
            "system": VocabularySuggestionPrompt.instructions,
            "messages": [[
                "role": "user",
                "content": VocabularySuggestionPrompt.input(for: transcript),
            ]],
        ])
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport.send(request) }
        catch { throw MeetingSummaryClientError.ambiguousOutcome(providerName) }
        guard (200..<300).contains(response.statusCode) else {
            throw MeetingSummaryClientError.httpStatus(providerName, response.statusCode)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = root["content"] as? [[String: Any]] else {
            throw MeetingSummaryClientError.invalidResponse(providerName)
        }
        if (root["stop_reason"] as? String) == "max_tokens" {
            throw MeetingSummaryClientError.truncatedOutput(providerName)
        }
        let text = content.filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw MeetingSummaryClientError.emptyOutput(providerName) }
        return text
    }
}

enum VocabularySuggestionParser {
    static let maximumTermLength = 40
    static let maximumSuggestions = 20

    /// Strictly parses the model reply. Anything other than a JSON array of objects
    /// with a string `term` is rejected as a whole, so no partial result is shown.
    static func parse(_ text: String) throws -> [VocabularySuggestion] {
        let body = stripCodeFence(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let data = body.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw VocabularySuggestionError.unparseable
        }
        return try items.map { item in
            guard let object = item as? [String: Any], let term = object["term"] as? String else {
                throw VocabularySuggestionError.unparseable
            }
            let heardAs = (object["heard_as"] as? [Any])?.compactMap { $0 as? String } ?? []
            return VocabularySuggestion(
                term: term, heardAs: heardAs, reason: object["reason"] as? String ?? ""
            )
        }
    }

    /// App-side filter rules: trim, length 1–40 without newlines, drop terms already in the
    /// vocabulary (case-insensitive), dedupe within the reply (case-insensitive), cap at 20.
    static func filter(
        _ suggestions: [VocabularySuggestion], existingTerms: [String]
    ) -> [VocabularySuggestion] {
        var seen = Set(existingTerms.map { normalized($0) })
        var result: [VocabularySuggestion] = []
        for suggestion in suggestions {
            let term = suggestion.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...maximumTermLength).contains(term.count),
                  term.rangeOfCharacter(from: .newlines) == nil,
                  seen.insert(normalized(term)).inserted
            else { continue }
            result.append(VocabularySuggestion(
                term: term, heardAs: suggestion.heardAs, reason: suggestion.reason
            ))
            if result.count == maximumSuggestions { break }
        }
        return result
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func stripCodeFence(_ text: String) -> String {
        guard text.hasPrefix("```"), text.hasSuffix("```"), text.count >= 6 else { return text }
        var lines = text.components(separatedBy: .newlines)
        guard lines.count >= 2 else { return text }
        lines.removeFirst()
        lines.removeLast()
        return lines.joined(separator: "\n")
    }
}
