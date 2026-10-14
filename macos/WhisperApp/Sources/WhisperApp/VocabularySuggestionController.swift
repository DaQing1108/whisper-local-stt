import Foundation
import Observation

/// Drives the "建議詞彙" flow. Only `requestSuggestions` sends the transcript out, and it is
/// called solely from the AI Summary button; nothing here writes vocabulary without an
/// explicit `add` / `addAll` from the user.
@MainActor
@Observable
final class VocabularySuggestionController {
    enum Status: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var suggestions: [VocabularySuggestion] = []
    private(set) var sourceTranscriptionID: UUID?
    private(set) var addError: String?
    private let clients: [MeetingSummaryProvider: any VocabularySuggesting]
    private let credentials: @MainActor @Sendable (MeetingSummaryProvider) throws -> String?

    var isLoading: Bool { status == .loading }

    init(
        clients: [MeetingSummaryProvider: any VocabularySuggesting] = [
            .openAI: OpenAIVocabularySuggestionClient(),
            .anthropic: AnthropicVocabularySuggestionClient(),
        ],
        credentials: @escaping @MainActor @Sendable (MeetingSummaryProvider) throws -> String? = {
            try LLMCredentialStore(provider: $0).load()
        }
    ) {
        self.clients = clients
        self.credentials = credentials
    }

    func requestSuggestions(
        transcriptionID: UUID,
        transcript: String,
        provider: MeetingSummaryProvider,
        existingTerms: [String]
    ) async {
        guard !isLoading else { return }
        status = .loading
        suggestions = []
        addError = nil
        sourceTranscriptionID = transcriptionID
        do {
            guard let client = clients[provider] else {
                throw MeetingSummaryClientError.invalidResponse(provider.displayName)
            }
            guard let key = try credentials(provider),
                  !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MeetingSummaryClientError.missingCredential(provider.displayName)
            }
            let reply = try await client.suggest(transcript: transcript, apiKey: key)
            suggestions = VocabularySuggestionParser.filter(
                try VocabularySuggestionParser.parse(reply), existingTerms: existingTerms
            )
            status = .loaded
        } catch {
            suggestions = []
            status = .failed(error.localizedDescription)
        }
    }

    func add(_ suggestion: VocabularySuggestion, to store: VocabularyStore) {
        do {
            try store.add(suggestion.term)
            suggestions.removeAll { $0.id == suggestion.id }
            addError = nil
        } catch {
            addError = "加入詞彙失敗：\(error.localizedDescription)"
        }
    }

    func addAll(to store: VocabularyStore) {
        guard !suggestions.isEmpty else { return }
        do {
            try store.addAll(suggestions.map(\.term))
            suggestions = []
            addError = nil
        } catch {
            addError = "加入詞彙失敗：\(error.localizedDescription)"
        }
    }
}
