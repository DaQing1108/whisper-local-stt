import Foundation
import Security

enum MeetingSummaryProvider: String, CaseIterable, Sendable {
    case openAI = "openai"
    case anthropic = "anthropic"

    var displayName: String { self == .openAI ? "OpenAI" : "Anthropic Claude" }
}

enum MeetingSummaryClientError: Error, Equatable {
    case missingCredential(String)
    case invalidResponse(String)
    case httpStatus(String, Int)
    case emptyOutput(String)
    case truncatedOutput(String)
    case ambiguousOutcome(String)
}

extension MeetingSummaryClientError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .missingCredential(provider):
            return "尚未設定 \(provider) API key。請展開「進階設定與整合」，儲存 \(provider) key 後再試。"
        case let .invalidResponse(provider):
            return "\(provider) 回傳的摘要格式無法解析，請稍後重試。"
        case let .httpStatus(provider, status):
            switch status {
            case 401, 403:
                return "\(provider) 驗證失敗（HTTP \(status)）。請在「進階設定與整合」重新儲存有效的 API key。"
            case 429:
                return "\(provider) 暫時拒絕請求（HTTP 429）。請檢查額度或稍後重試。"
            default:
                return "\(provider) 摘要服務失敗（HTTP \(status)），請稍後重試。"
            }
        case let .emptyOutput(provider):
            return "\(provider) 未回傳摘要內容，請稍後重試。"
        case let .truncatedOutput(provider):
            return "\(provider) 摘要超過輸出長度限制，未儲存不完整結果；請縮短逐字稿後重試。"
        case let .ambiguousOutcome(provider):
            return "無法確認 \(provider) 摘要結果，可能是網路連線中斷；請確認網路後重試。"
        }
    }
}

protocol MeetingSummaryHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionMeetingSummaryTransport: MeetingSummaryHTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MeetingSummaryClientError.invalidResponse("AI provider") }
        return (data, http)
    }
}

protocol MeetingSummaryGenerating: Sendable {
    var providerName: String { get }
    func generate(transcript: String, apiKey: String) async throws -> String
}

struct OpenAIMeetingSummaryClient: MeetingSummaryGenerating {
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

    func generate(transcript: String, apiKey: String) async throws -> String {
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
            "instructions": Self.instructions,
            "input": "請只根據以下逐字稿整理會議摘要：\n\n\(transcript)",
        ])
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport.send(request) }
        catch { throw MeetingSummaryClientError.ambiguousOutcome(providerName) }
        guard (200..<300).contains(response.statusCode) else {
            throw MeetingSummaryClientError.httpStatus(providerName, response.statusCode)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
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

    private static let instructions = """
    你是會議摘要助手。只能依逐字稿內容作答，不得虛構。使用逐字稿原文語言；中文使用繁體中文。
    固定輸出：## 摘要、## 決策、## 行動事項、## 待確認。資訊不足寫「未提及」。
    """
}

struct AnthropicMeetingSummaryClient: MeetingSummaryGenerating {
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

    func generate(transcript: String, apiKey: String) async throws -> String {
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
            "system": Self.instructions,
            "messages": [[
                "role": "user",
                "content": "請只根據以下逐字稿整理會議摘要：\n\n\(transcript)",
            ]],
        ])
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport.send(request) }
        catch { throw MeetingSummaryClientError.ambiguousOutcome(providerName) }
        guard (200..<300).contains(response.statusCode) else {
            throw MeetingSummaryClientError.httpStatus(providerName, response.statusCode)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
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

    private static let instructions = """
    你是會議摘要助手。只能依逐字稿內容作答，不得虛構。使用逐字稿原文語言；中文使用繁體中文。
    固定輸出：## 摘要、## 決策、## 行動事項、## 待確認。資訊不足寫「未提及」。
    """
}

struct LLMCredentialStore: Sendable {
    private let service = "com.via.whisper-swiftui.llm"
    private let account: String

    init(provider: MeetingSummaryProvider = .openAI) {
        account = provider == .openAI ? "openai-api-key" : "anthropic-api-key"
    }

    func save(apiKey: String) throws {
        let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw MeetingSummaryClientError.missingCredential("AI provider") }
        let data = Data(value.utf8)
        let update = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw NotionCredentialError.keychain(update) }
        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw NotionCredentialError.keychain(status) }
    }

    func load() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw NotionCredentialError.keychain(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw NotionCredentialError.invalidData
        }
        return value
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}
