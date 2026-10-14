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
    /// Suggestions whose `heardAs → term` correction rules should be created on add.
    /// Opt-in per suggestion; off by default.
    private(set) var correctionOptIns: Set<String> = []
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
        correctionOptIns = []
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

    func setIncludesCorrections(_ include: Bool, for suggestion: VocabularySuggestion) {
        if include, !suggestion.heardAs.isEmpty { correctionOptIns.insert(suggestion.id) }
        else { correctionOptIns.remove(suggestion.id) }
    }

    func add(
        _ suggestion: VocabularySuggestion, to store: VocabularyStore, corrections: CorrectionRuleStore? = nil
    ) {
        do {
            try store.add(suggestion.term)
            suggestions.removeAll { $0.id == suggestion.id }
            addError = addCorrections(for: [suggestion], to: corrections)
        } catch {
            addError = "加入詞彙失敗：\(error.localizedDescription)"
        }
    }

    func addAll(to store: VocabularyStore, corrections: CorrectionRuleStore? = nil) {
        guard !suggestions.isEmpty else { return }
        do {
            try store.addAll(suggestions.map(\.term))
            let added = suggestions
            suggestions = []
            addError = addCorrections(for: added, to: corrections)
        } catch {
            addError = "加入詞彙失敗：\(error.localizedDescription)"
        }
    }

    /// Creates `heardAs → term` rules for opted-in suggestions after their term was added.
    /// Returns a message for rules that could not be created (the term itself stays added).
    private func addCorrections(
        for added: [VocabularySuggestion], to corrections: CorrectionRuleStore?
    ) -> String? {
        guard let corrections else { return nil }
        var failures: [String] = []
        for suggestion in added where correctionOptIns.contains(suggestion.id) {
            correctionOptIns.remove(suggestion.id)
            let heardAs = suggestion.heardAs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            for heard in heardAs where !heard.isEmpty && heard != suggestion.term {
                do { try corrections.add(wrong: heard, right: suggestion.term) }
                catch { failures.append("\(heard)：\(error.localizedDescription)") }
            }
        }
        return failures.isEmpty ? nil : "已加入詞彙，但部分修正規則未建立：\(failures.joined(separator: "；"))"
    }
}
