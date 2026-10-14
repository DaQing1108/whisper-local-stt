import Foundation
import Testing
@testable import WhisperApp

/// Fake Worker: every comma-separated term costs 10 tokens against a 223 limit and the
/// leading terms are dropped, mirroring the Worker's whole-term trimming.
@MainActor
private final class FakeBudgetProvider: PromptBudgetProviding {
    private(set) var requests: [VocabularyBudgetInputs] = []
    var available = true
    var error: (any Error)?

    func promptBudget(modelName: String, domain: String, extraTerms: String) async throws -> PromptBudget {
        requests.append(VocabularyBudgetInputs(
            modelName: modelName, domain: domain, extraTerms: extraTerms, isWorkerReady: true
        ))
        if let error { throw error }
        guard available else { return .unavailable }
        let terms = extraTerms.components(separatedBy: ", ").filter { !$0.isEmpty }
        let tokens = terms.count * 10
        let overflow = max(0, Int((Double(tokens - 223) / 10).rounded(.up)))
        return PromptBudget(
            tokens: tokens, limit: 223, droppedTerms: Array(terms.prefix(overflow)), available: true
        )
    }
}

private func inputs(_ terms: [String], ready: Bool = true, model: String = "large-v3-turbo") -> VocabularyBudgetInputs {
    VocabularyBudgetInputs(
        modelName: model, domain: "general", extraTerms: terms.joined(separator: ", "), isWorkerReady: ready
    )
}

private func syntheticTerms(_ count: Int) -> [String] {
    (0..<count).map { String(format: "Zyntrix%02d", $0) }
}

@MainActor
struct VocabularyBudgetControllerTests {
    private func settle(_ controller: VocabularyBudgetController) async {
        await controller.pendingRefresh?.value
    }

    @Test func burstOfChangesSendsOneRequestWithLatestInputs() async {
        let provider = FakeBudgetProvider()
        let controller = VocabularyBudgetController(provider: provider, debounce: .milliseconds(50))

        for count in 1...5 { controller.scheduleRefresh(inputs(syntheticTerms(count))) }
        await settle(controller)

        #expect(provider.requests.count == 1)
        #expect(provider.requests.first?.extraTerms == syntheticTerms(5).joined(separator: ", "))
        #expect(controller.budget?.tokens == 50)
        #expect(!controller.isOverLimit)
    }

    @Test func modelChangeAlsoTriggersRecount() async {
        let provider = FakeBudgetProvider()
        let controller = VocabularyBudgetController(provider: provider, debounce: .milliseconds(10))

        controller.scheduleRefresh(inputs(syntheticTerms(3), model: "base"))
        await settle(controller)
        controller.scheduleRefresh(inputs(syntheticTerms(3), model: "large-v3-turbo"))
        await settle(controller)

        #expect(provider.requests.map(\.modelName) == ["base", "large-v3-turbo"])
    }

    @Test func overLimitMarksLeadingEnabledTermsAsNotApplied() async {
        let provider = FakeBudgetProvider()
        let controller = VocabularyBudgetController(provider: provider, debounce: .milliseconds(10))
        let terms = syntheticTerms(25).map { VocabularyTerm(value: $0) }

        controller.scheduleRefresh(inputs(terms.map(\.value)))
        await settle(controller)

        #expect(controller.budget?.tokens == 250)
        #expect(controller.budget?.limit == 223)
        #expect(controller.isOverLimit)
        #expect(controller.droppedTermIDs(in: terms) == Set(terms.prefix(3).map(\.id)))
    }

    @Test func nothingIsMarkedBeforeMeasurement() {
        let controller = VocabularyBudgetController(provider: nil)

        #expect(controller.status == .unknown)
        #expect(controller.droppedTermIDs(in: [VocabularyTerm(value: "Zyntrix")]).isEmpty)
    }

    @Test func termWithSeparatorIsMatchedPieceByPiece() async {
        let provider = FakeBudgetProvider()
        let controller = VocabularyBudgetController(provider: provider, debounce: .milliseconds(10))
        // 23 terms → 230 tokens → first term dropped; the vocabulary term "A、B" spans two prompt terms.
        let prompt = ["Quorvane、Plexidon"] + syntheticTerms(21)
        controller.scheduleRefresh(VocabularyBudgetInputs(
            modelName: "base", domain: "general",
            extraTerms: (["Quorvane", "Plexidon"] + syntheticTerms(21)).joined(separator: ", "),
            isWorkerReady: true
        ))
        await settle(controller)
        let terms = prompt.map { VocabularyTerm(value: $0) }

        #expect(controller.budget?.droppedTerms == ["Quorvane"])
        // Only half of "Quorvane、Plexidon" is dropped, so the term still partly applies → not marked.
        #expect(controller.droppedTermIDs(in: terms).isEmpty)
    }

    @Test func addingSuggestionsThatExceedLimitRaisesWarning() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VocabularyStore(fileURL: directory.appendingPathComponent("vocabulary.json"))
        try store.addAll(syntheticTerms(20))
        let provider = FakeBudgetProvider()
        let controller = VocabularyBudgetController(provider: provider, debounce: .milliseconds(10))
        controller.scheduleRefresh(inputs([store.activeTermsText]))
        await settle(controller)
        #expect(!controller.isOverLimit)

        try store.addAll(["Quorvane", "Plexidon", "Velmora"])  // 「全部加入」建議詞彙
        controller.scheduleRefresh(inputs([store.activeTermsText]))
        await settle(controller)

        #expect(controller.isOverLimit)
        #expect(controller.budget?.droppedTerms == ["Zyntrix00"])
        #expect(store.terms.count == 23)  // 只警示，不自動刪詞
    }

    @Test func modelNotDownloadedReportsUnavailableWithoutNumbers() async {
        let provider = FakeBudgetProvider()
        provider.available = false
        let controller = VocabularyBudgetController(provider: provider, debounce: .milliseconds(10))

        controller.scheduleRefresh(inputs(syntheticTerms(30)))
        await settle(controller)

        #expect(controller.status == .modelNotDownloaded)
        #expect(controller.budget == nil)
        #expect(!controller.isOverLimit)
    }

    @Test func workerNotReadySendsNoRequest() async {
        let provider = FakeBudgetProvider()
        let controller = VocabularyBudgetController(provider: provider, debounce: .milliseconds(10))

        controller.scheduleRefresh(inputs(syntheticTerms(3), ready: false))
        await settle(controller)

        #expect(provider.requests.isEmpty)
        #expect(controller.status == .workerUnavailable)
    }

    @Test func workerErrorReportsUnavailable() async {
        let provider = FakeBudgetProvider()
        provider.error = WorkerSupervisorError.workerUnavailable
        let controller = VocabularyBudgetController(provider: provider, debounce: .milliseconds(10))

        controller.scheduleRefresh(inputs(syntheticTerms(3)))
        await settle(controller)

        #expect(controller.status == .workerUnavailable)
    }

    @Test func promptBudgetDecodesWorkerPayload() {
        let measured = PromptBudget(payload: [
            "tokens": .number(231), "limit": .number(223),
            "dropped_terms": .array([.string("Zyntrix"), .string("Quorvane")]), "available": .bool(true),
        ])
        #expect(measured == PromptBudget(tokens: 231, limit: 223, droppedTerms: ["Zyntrix", "Quorvane"], available: true))
        #expect(measured.isOverLimit)
        #expect(PromptBudget(payload: ["available": .bool(false), "tokens": .number(0)]) == .unavailable)
        #expect(PromptBudget(payload: ["available": .bool(true)]) == .unavailable)
    }
}
