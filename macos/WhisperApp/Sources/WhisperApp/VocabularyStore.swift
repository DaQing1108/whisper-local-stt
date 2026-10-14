import Foundation
import Observation

struct VocabularyTerm: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var value: String
    var isEnabled: Bool

    init(id: UUID = UUID(), value: String, isEnabled: Bool = true) {
        self.id = id
        self.value = value
        self.isEnabled = isEnabled
    }
}

@MainActor
@Observable
final class VocabularyStore {
    private(set) var terms: [VocabularyTerm] = []
    private(set) var loadError: String?
    private(set) var writeError: String?
    private let fileURL: URL
    let usage: VocabularyUsageStore
    private let now: @MainActor () -> Date

    /// Prompt text in priority order. faster-whisper truncates the prompt from the front,
    /// so the most important terms go last.
    var activeTermsText: String {
        promptOrderedActiveTerms.map(\.value).joined(separator: ", ")
    }

    /// Enabled terms ordered by most recent activity, `max(addedAt, lastSeenAt)`, oldest
    /// first. A term with no recorded activity (added before usage tracking existed) gets a
    /// virtual time from its list position — earlier than any real date and increasing down
    /// the list — so legacy order is kept and the result is stable. Ties keep list order.
    var promptOrderedActiveTerms: [VocabularyTerm] {
        terms.enumerated()
            .filter { $0.element.isEnabled }
            .map { (index: $0.offset, term: $0.element, activity: activity(of: $0.element, index: $0.offset)) }
            .sorted { ($0.activity, $0.index) < ($1.activity, $1.index) }
            .map(\.term)
    }

    /// Most recent activity of a term, or nil when only the virtual list-position time applies.
    func lastActivity(of term: VocabularyTerm) -> Date? {
        let record = usage.usage[term.id]
        return [record?.addedAt, record?.lastSeenAt].compactMap { $0 }.max()
    }

    init(
        fileURL: URL = VocabularyStore.defaultFileURL(),
        usage: VocabularyUsageStore? = nil,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.fileURL = fileURL
        self.usage = usage ?? VocabularyUsageStore(
            fileURL: fileURL.deletingLastPathComponent().appendingPathComponent("vocabulary-usage.json")
        )
        self.now = now
        load()
    }

    /// Called when a finished transcript is written to history.
    func recordSeen(in text: String, at date: Date) {
        usage.recordSeen(in: text, terms: terms.filter(\.isEnabled), at: date)
    }

    /// One-time `lastSeenAt` backfill from existing history (no-op once done).
    func backfillUsageIfNeeded(from history: [TranscriptionHistoryEntry]) {
        usage.backfillIfNeeded(terms: terms, history: history)
    }

    private func activity(of term: VocabularyTerm, index: Int) -> Date {
        lastActivity(of: term) ?? Date(timeIntervalSince1970: TimeInterval(index))
    }

    func add(_ rawValue: String) throws {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              !terms.contains(where: { $0.value.compare(value, options: .caseInsensitive) == .orderedSame })
        else { return }
        let term = VocabularyTerm(value: value)
        try mutate { $0.append(term) }
        usage.recordAdded([term.id], at: now())
    }

    /// Adds several terms in one atomic write; duplicates (case-insensitive) are skipped
    /// with the same rules as `add`. Either every new term is persisted or none is.
    func addAll(_ rawValues: [String]) throws {
        var additions: [String] = []
        for rawValue in rawValues {
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty,
                  !(terms.map(\.value) + additions).contains(where: {
                      $0.compare(value, options: .caseInsensitive) == .orderedSame
                  })
            else { continue }
            additions.append(value)
        }
        guard !additions.isEmpty else { return }
        let added = additions.map { VocabularyTerm(value: $0) }
        try mutate { $0.append(contentsOf: added) }
        usage.recordAdded(added.map(\.id), at: now())
    }

    func toggle(_ term: VocabularyTerm) throws {
        try mutate { terms in
            guard let index = terms.firstIndex(where: { $0.id == term.id }) else { return }
            terms[index].isEnabled.toggle()
        }
    }

    func remove(_ term: VocabularyTerm) throws {
        try mutate { $0.removeAll { $0.id == term.id } }
        usage.forget(term.id)
    }

    private func mutate(_ body: (inout [VocabularyTerm]) -> Void) throws {
        let previous = terms
        body(&terms)
        do { try persist(); writeError = nil }
        catch { terms = previous; writeError = error.localizedDescription; throw error }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do { terms = try JSONDecoder().decode([VocabularyTerm].self, from: Data(contentsOf: fileURL)) }
        catch { terms = []; loadError = error.localizedDescription }
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(terms).write(to: fileURL, options: .atomic)
    }

    private static func defaultFileURL() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("WhisperSwiftUI", isDirectory: true)
            .appendingPathComponent("vocabulary.json")
    }
}
