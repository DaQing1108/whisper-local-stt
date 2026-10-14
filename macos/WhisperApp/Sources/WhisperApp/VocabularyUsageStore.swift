import Foundation
import Observation

/// Per-term activity used to order the vocabulary prompt. Stored in its own file
/// (`vocabulary-usage.json`) so `vocabulary.json` keeps its original format.
struct VocabularyUsage: Codable, Equatable, Sendable {
    var addedAt: Date?
    var lastSeenAt: Date?
}

@MainActor
@Observable
final class VocabularyUsageStore {
    private struct FileContents: Codable {
        var backfilled: Bool
        /// Keyed by `VocabularyTerm.id.uuidString` so the file is a plain JSON object.
        var terms: [String: VocabularyUsage]
    }

    private(set) var usage: [UUID: VocabularyUsage] = [:]
    private(set) var loadError: String?
    private(set) var writeError: String?
    /// True until the one-time scan of transcription history has been persisted.
    private(set) var needsBackfill = true
    /// Live and mixed recordings re-record the growing transcript every chunk; sightings
    /// closer together than this don't change the prompt order, so they skip the disk write.
    static let lastSeenGranularity: TimeInterval = 60
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    func recordAdded(_ ids: [UUID], at date: Date) {
        guard !ids.isEmpty else { return }
        for id in ids { usage[id, default: VocabularyUsage()].addedAt = date }
        persist()
    }

    /// Marks every term that appears in `text` as seen at `date` (never moves a date backwards).
    func recordSeen(in text: String, terms: [VocabularyTerm], at date: Date) {
        var changed = false
        for term in terms where VocabularyTermMatcher.contains(text, term: term.value) {
            if let previous = usage[term.id]?.lastSeenAt,
               date.timeIntervalSince(previous) < Self.lastSeenGranularity { continue }
            usage[term.id, default: VocabularyUsage()].lastSeenAt = date
            changed = true
        }
        if changed { persist() }
    }

    /// One-time fill of `lastSeenAt` from existing history; later launches skip it.
    func backfillIfNeeded(terms: [VocabularyTerm], history: [TranscriptionHistoryEntry]) {
        guard needsBackfill else { return }
        for entry in history.sorted(by: { $0.completedAt < $1.completedAt }) {
            for term in terms where VocabularyTermMatcher.contains(entry.text, term: term.value) {
                usage[term.id, default: VocabularyUsage()].lastSeenAt = entry.completedAt
            }
        }
        needsBackfill = false
        persist()
    }

    func forget(_ id: UUID) {
        guard usage.removeValue(forKey: id) != nil else { return }
        persist()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let contents = try JSONDecoder.usage.decode(FileContents.self, from: Data(contentsOf: fileURL))
            usage = Dictionary(contents.terms.compactMap { key, value in
                UUID(uuidString: key).map { ($0, value) }
            }, uniquingKeysWith: { first, _ in first })
            needsBackfill = !contents.backfilled
        } catch {
            // Unreadable usage only affects prompt order: run with empty data (the next write
            // replaces the file) and skip the history rescan.
            usage = [:]
            needsBackfill = false
            loadError = error.localizedDescription
        }
    }

    /// Failures are recorded but never thrown: usage must not block adding terms or transcription.
    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try JSONEncoder.usage.encode(FileContents(
                backfilled: !needsBackfill,
                terms: Dictionary(uniqueKeysWithValues: usage.map { ($0.key.uuidString, $0.value) })
            ))
            try data.write(to: fileURL, options: .atomic)
            writeError = nil
        } catch {
            writeError = error.localizedDescription
        }
    }
}

enum VocabularyTermMatcher {
    /// Case-insensitive substring match. A pure-ASCII term must not touch an ASCII letter
    /// or digit on either side, so `KM` does not match inside `KMS`.
    static func contains(_ text: String, term rawTerm: String) -> Bool {
        let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return false }
        let needsBoundary = term.unicodeScalars.allSatisfy(\.isASCII)
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: term, options: .caseInsensitive, range: searchRange) {
            if !needsBoundary || (isBoundary(before: found.lowerBound, in: text)
                                  && isBoundary(after: found.upperBound, in: text)) {
                return true
            }
            searchRange = text.index(after: found.lowerBound)..<text.endIndex
        }
        return false
    }

    private static func isBoundary(before index: String.Index, in text: String) -> Bool {
        guard index > text.startIndex else { return true }
        return !isASCIIAlphanumeric(text[text.index(before: index)])
    }

    private static func isBoundary(after index: String.Index, in text: String) -> Bool {
        guard index < text.endIndex else { return true }
        return !isASCIIAlphanumeric(text[index])
    }

    private static func isASCIIAlphanumeric(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber)
    }
}

private extension JSONEncoder {
    static var usage: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var usage: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
