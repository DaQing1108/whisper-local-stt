import SwiftUI

extension ContentView {
    /// Suggestions are based on the transcript the user currently sees (`transcriptDraft`),
    /// which may include unsaved edits such as speaker renames.
    var canRequestVocabularySuggestions: Bool {
        guard currentEntry != nil, !vocabularySuggestions.isLoading else { return false }
        return !transcriptDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder var vocabularySuggestionList: some View {
        if vocabularySuggestions.sourceTranscriptionID == currentEntry?.id {
            if case let .failed(message) = vocabularySuggestions.status {
                Text(message).font(.caption).foregroundStyle(.red)
            }
            if let addError = vocabularySuggestions.addError {
                Text(addError).font(.caption).foregroundStyle(.red)
            }
            if vocabularySuggestions.status == .loaded { vocabularyBudgetSuggestionWarning }
            if vocabularySuggestions.status == .loaded && vocabularySuggestions.suggestions.isEmpty {
                Text("沒有新的建議詞彙").font(.caption).foregroundStyle(.secondary)
            }
            if !vocabularySuggestions.suggestions.isEmpty {
                HStack {
                    Text("建議詞彙（\(vocabularySuggestions.suggestions.count)）").font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("全部加入") { vocabularySuggestions.addAll(to: vocabulary) }
                }
                ForEach(vocabularySuggestions.suggestions) { suggestion in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.term).font(.body.weight(.medium))
                            if !suggestion.heardAs.isEmpty {
                                Text("誤聽為：\(suggestion.heardAs.joined(separator: "、"))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if !suggestion.reason.isEmpty {
                                Text(suggestion.reason).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("加入") { vocabularySuggestions.add(suggestion, to: vocabulary) }
                    }
                }
            }
        }
    }

    /// The only caller of `requestSuggestions`: invoked from the「建議詞彙」button action.
    func requestVocabularySuggestions() {
        guard let entry = currentEntry else { return }
        let transcript = transcriptDraft
        let provider = settings.summaryProvider
        let existing = vocabulary.terms.map(\.value)
        Task {
            await vocabularySuggestions.requestSuggestions(
                transcriptionID: entry.id, transcript: transcript,
                provider: provider, existingTerms: existing
            )
        }
    }
}
