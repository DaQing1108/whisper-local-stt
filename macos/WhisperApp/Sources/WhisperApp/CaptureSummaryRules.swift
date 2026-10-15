import Foundation

/// One-line settings summary next to「開始錄音」, e.g.「混音 · turbo · 中文 · 詞庫 220/223」.
@MainActor
enum CaptureSummaryRules {
    struct Summary: Equatable {
        /// Mode · model · language.
        let main: String
        /// 「詞庫 X/223」, nil when the budget hasn't been measured.
        let vocabulary: String?
        let isVocabularyOverLimit: Bool
    }

    static func summary(
        mode: AudioInputMode, includesMicrophone: Bool, model: String, language: String, budget: PromptBudget?
    ) -> Summary {
        let main = [modeText(mode, includesMicrophone: includesMicrophone), modelText(model), languageText(language)]
            .joined(separator: " · ")
        guard let budget, budget.available else {
            return Summary(main: main, vocabulary: nil, isVocabularyOverLimit: false)
        }
        return Summary(main: main, vocabulary: "詞庫 \(budget.tokens)/\(budget.limit)", isVocabularyOverLimit: budget.isOverLimit)
    }

    static func modeText(_ mode: AudioInputMode, includesMicrophone: Bool) -> String {
        mode == .mixed && !includesMicrophone ? "混音（僅系統）" : mode.title
    }

    /// The picker's display name without its（說明）; large-v3-turbo is shortened to「turbo」.
    static func modelText(_ model: String) -> String {
        if model == "large-v3-turbo" { return "turbo" }
        let name = AppSettingsStore.displayName(for: model)
        return name.components(separatedBy: "（").first?.trimmingCharacters(in: .whitespaces) ?? name
    }

    static func languageText(_ language: String) -> String {
        switch language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "": "自動偵測"
        case "zh": "中文"
        case "en": "英文"
        case "ja": "日文"
        case let other: other
        }
    }
}
