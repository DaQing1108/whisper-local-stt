import Foundation
import Observation

@MainActor
protocol PromptBudgetProviding: AnyObject {
    func promptBudget(modelName: String, domain: String, extraTerms: String) async throws -> PromptBudget
}

extension WorkerSupervisor: PromptBudgetProviding {}

/// What the transcription prompt is built from; any change triggers a debounced recount.
struct VocabularyBudgetInputs: Equatable, Sendable {
    let modelName: String
    let domain: String
    let extraTerms: String
    let isWorkerReady: Bool
}

/// Keeps the latest token usage of the vocabulary prompt. Only reports usage; it never
/// removes or disables vocabulary terms — the user decides what to drop.
@MainActor
@Observable
final class VocabularyBudgetController {
    enum Status: Equatable {
        case unknown
        case measured(PromptBudget)
        case modelNotDownloaded
        case workerUnavailable
    }

    private(set) var status: Status = .unknown
    private(set) var pendingRefresh: Task<Void, Never>?
    private weak var provider: (any PromptBudgetProviding)?
    private let debounce: Duration
    private var generation = 0

    init(provider: (any PromptBudgetProviding)?, debounce: Duration = .milliseconds(400)) {
        self.provider = provider
        self.debounce = debounce
    }

    var budget: PromptBudget? {
        if case .measured(let budget) = status { return budget }
        return nil
    }

    var isOverLimit: Bool { budget?.isOverLimit ?? false }

    /// Restarts the debounce window; only the last call within it reaches the Worker.
    func scheduleRefresh(_ inputs: VocabularyBudgetInputs) {
        pendingRefresh?.cancel()
        generation += 1
        let current = generation
        pendingRefresh = Task { [weak self, debounce] in
            do { try await Task.sleep(for: debounce) } catch { return }
            await self?.refresh(inputs, generation: current)
        }
    }

    private func refresh(_ inputs: VocabularyBudgetInputs, generation requested: Int) async {
        guard inputs.isWorkerReady, let provider else {
            status = .workerUnavailable
            return
        }
        let result: Status
        do {
            let budget = try await provider.promptBudget(
                modelName: inputs.modelName, domain: inputs.domain, extraTerms: inputs.extraTerms
            )
            result = budget.available ? .measured(budget) : .modelNotDownloaded
        } catch {
            result = .workerUnavailable
        }
        guard requested == generation else { return }
        status = result
    }

    /// IDs of enabled vocabulary terms the Worker will drop. The Worker drops whole terms
    /// from the front of the prompt (domain terms first, then vocabulary in prompt order),
    /// so pass `VocabularyStore.promptOrderedActiveTerms` — the order actually sent, not the
    /// list order — and the dropped vocabulary is a leading run of it.
    func droppedTermIDs(in promptOrderedTerms: [VocabularyTerm]) -> Set<UUID> {
        guard let budget, !budget.droppedTerms.isEmpty else { return [] }
        let dropped = Set(budget.droppedTerms)
        var ids: Set<UUID> = []
        for term in promptOrderedTerms {
            let pieces = Self.promptPieces(term.value)
            guard !pieces.isEmpty, pieces.allSatisfy(dropped.contains) else { break }
            ids.insert(term.id)
        }
        return ids
    }

    /// Mirrors the Worker's term separators (`,`、`、`、`，`) so a term containing one
    /// is matched piece by piece.
    private static func promptPieces(_ value: String) -> [String] {
        value.components(separatedBy: CharacterSet(charactersIn: ",、，"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
