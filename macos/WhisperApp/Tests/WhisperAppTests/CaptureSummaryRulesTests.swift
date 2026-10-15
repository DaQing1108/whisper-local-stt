import Foundation
import Testing
@testable import WhisperApp

@MainActor
struct CaptureSummaryRulesTests {
    private let measured = PromptBudget(tokens: 220, limit: 223, droppedTerms: [], available: true)
    private let over = PromptBudget(tokens: 228, limit: 223, droppedTerms: ["x"], available: true)

    // AC-A1
    @Test func modeModelLanguageAndBudget() {
        let summary = CaptureSummaryRules.summary(
            mode: .mixed, includesMicrophone: true, model: "large-v3-turbo", language: "zh", budget: measured
        )
        #expect(summary == .init(main: "混音 · turbo · 中文", vocabulary: "詞庫 220/223", isVocabularyOverLimit: false))

        let systemOnly = CaptureSummaryRules.summary(
            mode: .mixed, includesMicrophone: false, model: "large-v3", language: "", budget: over
        )
        #expect(systemOnly.main == "混音（僅系統） · large-v3 · 自動偵測")
        #expect(systemOnly.vocabulary == "詞庫 228/223")
        #expect(systemOnly.isVocabularyOverLimit)

        let standard = CaptureSummaryRules.summary(
            mode: .standard, includesMicrophone: false, model: "base", language: "en", budget: nil
        )
        #expect(standard == .init(main: "標準 · base · 英文", vocabulary: nil, isVocabularyOverLimit: false))

        let live = CaptureSummaryRules.summary(
            mode: .live, includesMicrophone: true, model: "small", language: "ja", budget: .unavailable
        )
        #expect(live == .init(main: "即時 · small · 日文", vocabulary: nil, isVocabularyOverLimit: false))
    }

    @Test func modelAndLanguageTexts() {
        #expect(CaptureSummaryRules.modelText("large-v3-turbo") == "turbo")
        #expect(CaptureSummaryRules.modelText("large-v3") == "large-v3")          // 括號說明不顯示
        #expect(CaptureSummaryRules.modelText("medium") == "medium")
        #expect(CaptureSummaryRules.languageText("ZH") == "中文")
        #expect(CaptureSummaryRules.languageText("ko") == "ko")                     // 其他代碼原樣
    }
}
