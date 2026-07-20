import Foundation
import Observation

@MainActor
@Observable
final class HistoryDeletionCoordinator {
    private(set) var pendingDeletionIDs: Set<UUID> = []
    private(set) var errorMessage: String?
    private let history: TranscriptionHistoryStore
    private let summaries: MeetingSummaryStore
    private let settings: AppSettingsStore
    private let tombstoneURL: URL

    init(
        history: TranscriptionHistoryStore,
        summaries: MeetingSummaryStore,
        settings: AppSettingsStore,
        tombstoneURL: URL = HistoryDeletionCoordinator.defaultTombstoneURL()
    ) {
        self.history = history
        self.summaries = summaries
        self.settings = settings
        self.tombstoneURL = tombstoneURL
        loadTombstone()
        try? reconcile()
    }

    func delete(_ entry: TranscriptionHistoryEntry) throws {
        try delete(ids: Set([entry.id])) { try history.remove(entry) }
    }

    func clearAll() throws -> Set<UUID> {
        let ids = Set(history.entries.map(\.id))
        try delete(ids: ids) { try history.clearAll() }
        return ids
    }

    func updateRetention(_ maximum: Int) throws -> Set<UUID> {
        let ids = Set(history.entries.dropFirst(maximum).map(\.id))
        try delete(ids: ids) { _ = try history.updateMaximumEntries(maximum) }
        return ids
    }

    func reconcile() throws {
        guard !pendingDeletionIDs.isEmpty else { return }
        do {
            try history.remove(ids: pendingDeletionIDs)
            try summaries.remove(transcriptionIDs: pendingDeletionIDs)
            settings.clearNotionOutcomeAmbiguous(entryIDs: pendingDeletionIDs)
            pendingDeletionIDs.removeAll()
            try persistTombstone()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    private func delete(ids: Set<UUID>, historyMutation: () throws -> Void) throws {
        guard !ids.isEmpty else { try historyMutation(); return }
        pendingDeletionIDs.formUnion(ids)
        try persistTombstone()
        do {
            try historyMutation()
            try summaries.remove(transcriptionIDs: ids)
            settings.clearNotionOutcomeAmbiguous(entryIDs: ids)
            pendingDeletionIDs.subtract(ids)
            try persistTombstone()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    private func loadTombstone() {
        guard FileManager.default.fileExists(atPath: tombstoneURL.path) else { return }
        do { pendingDeletionIDs = try JSONDecoder().decode(Set<UUID>.self, from: Data(contentsOf: tombstoneURL)) }
        catch { errorMessage = error.localizedDescription }
    }

    private func persistTombstone() throws {
        try FileManager.default.createDirectory(at: tombstoneURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(pendingDeletionIDs).write(to: tombstoneURL, options: .atomic)
    }

    static func defaultTombstoneURL() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("WhisperSwiftUI", isDirectory: true)
            .appendingPathComponent("pending-history-deletions.json")
    }
}
