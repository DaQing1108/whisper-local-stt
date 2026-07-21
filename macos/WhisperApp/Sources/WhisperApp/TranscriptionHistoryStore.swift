import Foundation
import Observation

struct TranscriptionSegment: Codable, Equatable, Sendable {
    let start: Double
    let end: Double
    let text: String
}

struct TranscriptionHistoryEntry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let completedAt: Date
    let audioPath: String
    let model: String
    let language: String?
    var text: String
    let segments: [TranscriptionSegment]
    let durationSeconds: Double?
    let domain: String
    let extraTerms: String
    var obsidianNotePath: String?
    var notionChildPageID: String?

    init(
        id: UUID = UUID(),
        completedAt: Date = Date(),
        audioPath: String,
        model: String,
        language: String?,
        text: String,
        segments: [TranscriptionSegment] = [],
        durationSeconds: Double? = nil,
        domain: String = "general",
        extraTerms: String = "",
        obsidianNotePath: String? = nil,
        notionChildPageID: String? = nil
    ) {
        self.id = id
        self.completedAt = completedAt
        self.audioPath = audioPath
        self.model = model
        self.language = language
        self.text = text
        self.segments = segments
        self.durationSeconds = durationSeconds
        self.domain = domain
        self.extraTerms = extraTerms
        self.obsidianNotePath = obsidianNotePath
        self.notionChildPageID = notionChildPageID
    }

    enum CodingKeys: String, CodingKey {
        case id, completedAt, audioPath, model, language, text, segments, durationSeconds, domain, extraTerms
        case obsidianNotePath, notionChildPageID
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        completedAt = try values.decode(Date.self, forKey: .completedAt)
        audioPath = try values.decode(String.self, forKey: .audioPath)
        model = try values.decode(String.self, forKey: .model)
        language = try values.decodeIfPresent(String.self, forKey: .language)
        text = try values.decode(String.self, forKey: .text)
        segments = try values.decodeIfPresent([TranscriptionSegment].self, forKey: .segments) ?? []
        durationSeconds = try values.decodeIfPresent(Double.self, forKey: .durationSeconds)
        domain = try values.decodeIfPresent(String.self, forKey: .domain) ?? "general"
        extraTerms = try values.decodeIfPresent(String.self, forKey: .extraTerms) ?? ""
        obsidianNotePath = try values.decodeIfPresent(String.self, forKey: .obsidianNotePath)
        notionChildPageID = try values.decodeIfPresent(String.self, forKey: .notionChildPageID)
    }
}

@MainActor
@Observable
final class TranscriptionHistoryStore {
    private(set) var entries: [TranscriptionHistoryEntry] = []
    private(set) var loadError: String?
    private(set) var writeError: String?
    private let fileURL: URL
    private var maximumEntries: Int

    init(fileURL: URL = TranscriptionHistoryStore.defaultFileURL(), maximumEntries: Int = 200) {
        self.fileURL = fileURL
        self.maximumEntries = maximumEntries
        load()
    }

    @discardableResult
    func recordCompleted(
        audioURL: URL,
        model: String,
        language: String?,
        text: String,
        segments: [TranscriptionSegment] = [],
        durationSeconds: Double? = nil,
        domain: String = "general",
        extraTerms: String = ""
    ) throws -> TranscriptionHistoryEntry {
        let previous = entries
        let entry = TranscriptionHistoryEntry(
            id: UUID(),
            completedAt: Date(),
            audioPath: audioURL.path,
            model: model,
            language: language?.isEmpty == false ? language : nil,
            text: text,
            segments: segments,
            durationSeconds: durationSeconds,
            domain: domain,
            extraTerms: extraTerms
        )
        entries.insert(entry, at: 0)
        if entries.count > maximumEntries { entries.removeLast(entries.count - maximumEntries) }
        do {
            try persist()
            writeError = nil
        } catch {
            entries = previous
            writeError = error.localizedDescription
            throw error
        }
        return entry
    }

    func updateText(id: UUID, text: String) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let previous = entries
        entries[index].text = text
        do {
            try persist()
            writeError = nil
        } catch {
            entries = previous
            writeError = error.localizedDescription
            throw error
        }
    }

    @discardableResult
    func updateResult(
        id: UUID,
        text: String,
        segments: [TranscriptionSegment],
        durationSeconds: Double?,
        audioURL: URL? = nil
    ) throws -> TranscriptionHistoryEntry? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        let previous = entries
        let existing = entries[index]
        entries[index] = TranscriptionHistoryEntry(
            id: existing.id,
            completedAt: existing.completedAt,
            audioPath: audioURL?.path ?? existing.audioPath,
            model: existing.model,
            language: existing.language,
            text: text,
            segments: segments,
            durationSeconds: durationSeconds,
            domain: existing.domain,
            extraTerms: existing.extraTerms,
            obsidianNotePath: existing.obsidianNotePath,
            notionChildPageID: existing.notionChildPageID
        )
        do {
            try persist()
            writeError = nil
            return entries[index]
        } catch {
            entries = previous
            writeError = error.localizedDescription
            throw error
        }
    }

    func updateObsidianNotePath(id: UUID, path: String) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let previous = entries
        entries[index].obsidianNotePath = path
        do {
            try persist()
            writeError = nil
        } catch {
            entries = previous
            writeError = error.localizedDescription
            throw error
        }
    }

    func updateNotionChildPageID(id: UUID, pageID: String) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let previous = entries
        entries[index].notionChildPageID = pageID
        do {
            try persist()
            writeError = nil
        } catch {
            entries = previous
            writeError = error.localizedDescription
            throw error
        }
    }

    func remove(_ entry: TranscriptionHistoryEntry) throws {
        let previous = entries
        entries.removeAll { $0.id == entry.id }
        do {
            try persist()
            writeError = nil
        } catch {
            entries = previous
            writeError = error.localizedDescription
            throw error
        }
    }

    func remove(ids: Set<UUID>) throws {
        guard !ids.isEmpty else { return }
        let previous = entries
        entries.removeAll { ids.contains($0.id) }
        do { try persist(); writeError = nil }
        catch { entries = previous; writeError = error.localizedDescription; throw error }
    }

    func clearAll() throws {
        let previous = entries
        entries.removeAll()
        do { try persist(); writeError = nil }
        catch { entries = previous; writeError = error.localizedDescription; throw error }
    }

    @discardableResult
    func updateMaximumEntries(_ maximum: Int) throws -> Set<UUID> {
        guard maximum > 0 else { return [] }
        let previousEntries = entries
        let previousMaximum = maximumEntries
        maximumEntries = maximum
        let removed = Set(entries.dropFirst(maximum).map(\.id))
        if entries.count > maximum { entries.removeLast(entries.count - maximum) }
        do { try persist(); writeError = nil }
        catch {
            entries = previousEntries
            maximumEntries = previousMaximum
            writeError = error.localizedDescription
            throw error
        }
        return removed
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            entries = try JSONDecoder().decode([TranscriptionHistoryEntry].self, from: Data(contentsOf: fileURL))
            loadError = nil
        } catch {
            entries = []
            loadError = error.localizedDescription
        }
    }

    private func persist() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
    }

    private static func defaultFileURL() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("WhisperSwiftUI", isDirectory: true)
            .appendingPathComponent("transcription-history.json")
    }
}
