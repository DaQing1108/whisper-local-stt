import Foundation
import Observation

@MainActor
@Observable
final class MeetingSummaryController {
    private(set) var activeTranscriptionID: UUID?
    private(set) var lastError: String?
    private let store: MeetingSummaryStore
    private let generators: [MeetingSummaryProvider: any MeetingSummaryGenerating]
    private let credentials: @MainActor @Sendable (MeetingSummaryProvider) throws -> String?

    init(
        store: MeetingSummaryStore,
        generators: [MeetingSummaryProvider: any MeetingSummaryGenerating] = [
            .openAI: OpenAIMeetingSummaryClient(),
            .anthropic: AnthropicMeetingSummaryClient(),
        ],
        credentials: @escaping @MainActor @Sendable (MeetingSummaryProvider) throws -> String? = {
            try LLMCredentialStore(provider: $0).load()
        }
    ) {
        self.store = store
        self.generators = generators
        self.credentials = credentials
    }

    func generate(
        for entry: TranscriptionHistoryEntry, title: String, provider: MeetingSummaryProvider = .openAI
    ) async {
        guard activeTranscriptionID == nil else { return }
        activeTranscriptionID = entry.id
        lastError = nil
        defer { activeTranscriptionID = nil }
        do {
            guard let generator = generators[provider] else {
                throw MeetingSummaryClientError.invalidResponse(provider.displayName)
            }
            _ = try store.begin(
                transcriptionID: entry.id, title: title, provider: generator.providerName
            )
            guard let key = try credentials(provider), !key.isEmpty else {
                throw MeetingSummaryClientError.missingCredential(provider.displayName)
            }
            let text = try await generator.generate(transcript: entry.text, apiKey: key)
            try store.complete(
                transcriptionID: entry.id, generatedText: text, provider: generator.providerName
            )
        } catch {
            let message = error.localizedDescription
            do { try store.fail(transcriptionID: entry.id, message: message) }
            catch {
                lastError = "\(message); summary state could not be persisted: \(error.localizedDescription)"
                store.markUnpersistedFailure(transcriptionID: entry.id, message: lastError!)
                return
            }
            lastError = message
        }
    }
}
