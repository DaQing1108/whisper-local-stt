import SwiftUI

extension ContentView {
    /// Same model / domain / extra terms the transcription commands send, so the usage
    /// shown matches what the Worker will actually trim.
    var vocabularyBudgetInputs: VocabularyBudgetInputs {
        VocabularyBudgetInputs(
            modelName: settings.defaultModel,
            domain: settings.domain,
            extraTerms: effectiveExtraTerms,
            isWorkerReady: worker.state == .ready
        )
    }

    @ViewBuilder var vocabularyBudgetRow: some View {
        switch vocabularyBudget.status {
        case .measured(let budget):
            VStack(alignment: .leading, spacing: 2) {
                Text("\(budget.tokens) / \(budget.limit) tokens")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(budget.isOverLimit ? DaylightPalette.accentRecord : .secondary)
                if budget.isOverLimit {
                    Label(vocabularyBudgetWarning(budget), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(DaylightPalette.accentRecord)
                }
            }
        case .modelNotDownloaded:
            Text("尚未下載模型，無法計算用量").font(.caption).foregroundStyle(.secondary)
        case .workerUnavailable:
            Text("Worker 未就緒，暫時無法計算用量").font(.caption).foregroundStyle(.secondary)
        case .unknown:
            EmptyView()
        }
    }

    /// Shown under the「建議詞彙」list when adding suggestions pushed the prompt over budget.
    @ViewBuilder var vocabularyBudgetSuggestionWarning: some View {
        if let budget = vocabularyBudget.budget, budget.isOverLimit {
            Label(vocabularyBudgetWarning(budget), systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(DaylightPalette.accentRecord)
        }
    }

    func vocabularyBudgetWarning(_ budget: PromptBudget) -> String {
        "詞彙超過 \(budget.limit) tokens 上限，開頭 \(budget.droppedTerms.count) 個詞不會套用；請到詞庫停用或刪除較不重要的詞"
    }
}
