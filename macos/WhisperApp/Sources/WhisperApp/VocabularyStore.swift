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

    var activeTermsText: String {
        terms.filter(\.isEnabled).map(\.value).joined(separator: ", ")
    }

    init(fileURL: URL = VocabularyStore.defaultFileURL()) {
        self.fileURL = fileURL
        load()
    }

    func add(_ rawValue: String) throws {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              !terms.contains(where: { $0.value.compare(value, options: .caseInsensitive) == .orderedSame })
        else { return }
        try mutate { $0.append(VocabularyTerm(value: value)) }
    }

    func toggle(_ term: VocabularyTerm) throws {
        try mutate { terms in
            guard let index = terms.firstIndex(where: { $0.id == term.id }) else { return }
            terms[index].isEnabled.toggle()
        }
    }

    func remove(_ term: VocabularyTerm) throws {
        try mutate { $0.removeAll { $0.id == term.id } }
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
