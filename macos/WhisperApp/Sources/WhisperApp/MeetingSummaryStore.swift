import Foundation
import Observation

enum MeetingSummaryStatus: String, Codable, Sendable {
    case empty, generating, completed, failed
}

struct MeetingSummary: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let transcriptionID: UUID
    let meetingID: UUID
    var meetingTitle: String
    var generatedText: String
    var editedText: String
    var provider: String
    var status: MeetingSummaryStatus
    var errorMessage: String?
    let createdAt: Date
    var updatedAt: Date

    var effectiveText: String {
        let edited = editedText.trimmingCharacters(in: .whitespacesAndNewlines)
        return edited.isEmpty ? generatedText : editedText
    }

    init(
        id: UUID = UUID(), transcriptionID: UUID, meetingID: UUID = UUID(),
        meetingTitle: String, generatedText: String = "", editedText: String = "",
        provider: String = "", status: MeetingSummaryStatus = .empty,
        errorMessage: String? = nil, createdAt: Date = Date(), updatedAt: Date = Date()
    ) {
        self.id = id
        self.transcriptionID = transcriptionID
        self.meetingID = meetingID
        self.meetingTitle = meetingTitle
        self.generatedText = generatedText
        self.editedText = editedText
        self.provider = provider
        self.status = status
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@MainActor
@Observable
final class MeetingSummaryStore {
    private(set) var summaries: [MeetingSummary] = []
    private(set) var loadError: String?
    private(set) var writeError: String?
    private let fileURL: URL
    private let now: @Sendable () -> Date

    init(
        fileURL: URL = MeetingSummaryStore.defaultFileURL(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.fileURL = fileURL
        self.now = now
        load()
    }

    func summary(for transcriptionID: UUID) -> MeetingSummary? {
        summaries.first { $0.transcriptionID == transcriptionID }
    }

    @discardableResult
    func begin(transcriptionID: UUID, title: String, provider: String) throws -> MeetingSummary {
        var summary = summary(for: transcriptionID) ?? MeetingSummary(
            transcriptionID: transcriptionID, meetingTitle: title, createdAt: now(), updatedAt: now()
        )
        summary.meetingTitle = title
        summary.provider = provider
        summary.status = .generating
        summary.errorMessage = nil
        summary.updatedAt = now()
        try replaceAndPersist(summary)
        return summary
    }

    func complete(transcriptionID: UUID, generatedText: String, provider: String) throws {
        guard var summary = summary(for: transcriptionID) else { return }
        summary.generatedText = generatedText
        summary.provider = provider
        summary.status = .completed
        summary.errorMessage = nil
        summary.updatedAt = now()
        try replaceAndPersist(summary)
    }

    func fail(transcriptionID: UUID, message: String) throws {
        guard var summary = summary(for: transcriptionID) else { return }
        summary.status = .failed
        summary.errorMessage = message
        summary.updatedAt = now()
        try replaceAndPersist(summary)
    }

    func saveEdit(transcriptionID: UUID, title: String, text: String) throws {
        guard var summary = summary(for: transcriptionID) else { return }
        summary.meetingTitle = title
        summary.editedText = text == summary.generatedText ? "" : text
        summary.updatedAt = now()
        try replaceAndPersist(summary)
    }

    func markUnpersistedFailure(transcriptionID: UUID, message: String) {
        guard let index = summaries.firstIndex(where: { $0.transcriptionID == transcriptionID }) else {
            writeError = message
            return
        }
        summaries[index].status = .failed
        summaries[index].errorMessage = message
        summaries[index].updatedAt = now()
        writeError = message
    }

    func remove(transcriptionIDs: Set<UUID>) throws {
        guard !transcriptionIDs.isEmpty else { return }
        let previous = summaries
        summaries.removeAll { transcriptionIDs.contains($0.transcriptionID) }
        do { try persist(); writeError = nil }
        catch { summaries = previous; writeError = error.localizedDescription; throw error }
    }

    private func replaceAndPersist(_ summary: MeetingSummary) throws {
        let previous = summaries
        if let index = summaries.firstIndex(where: { $0.transcriptionID == summary.transcriptionID }) {
            summaries[index] = summary
        } else {
            summaries.insert(summary, at: 0)
        }
        do {
            try persist()
            writeError = nil
        } catch {
            summaries = previous
            writeError = error.localizedDescription
            throw error
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            summaries = try JSONDecoder().decode([MeetingSummary].self, from: Data(contentsOf: fileURL))
            var recoveredInterruptedGeneration = false
            for index in summaries.indices where summaries[index].status == .generating {
                summaries[index].status = .failed
                summaries[index].errorMessage = "Summary generation was interrupted"
                summaries[index].updatedAt = now()
                recoveredInterruptedGeneration = true
            }
            if recoveredInterruptedGeneration { try persist() }
            loadError = nil
        } catch {
            summaries = []
            loadError = error.localizedDescription
        }
    }

    private func persist() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try JSONEncoder().encode(summaries).write(to: fileURL, options: .atomic)
    }

    private static func defaultFileURL() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("WhisperSwiftUI", isDirectory: true)
            .appendingPathComponent("meeting-summaries.json")
    }
}
