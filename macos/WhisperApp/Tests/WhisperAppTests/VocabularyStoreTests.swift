import Foundation
import Testing
@testable import WhisperApp

@MainActor
struct VocabularyStoreTests {
    @Test func persistsUniqueTermsAndEnabledSelection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("vocabulary.json")
        let store = VocabularyStore(fileURL: url)
        try store.add("VIA")
        try store.add("Whisper")
        try store.add("via")
        try store.toggle(store.terms[1])

        let restored = VocabularyStore(fileURL: url)
        #expect(restored.terms.count == 2)
        #expect(restored.activeTermsText == "VIA")
    }

    @Test func removeIsAtomicAndPersists() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("vocabulary.json")
        let store = VocabularyStore(fileURL: url)
        try store.add("AeroFit Pro")
        try store.remove(store.terms[0])
        #expect(VocabularyStore(fileURL: url).terms.isEmpty)
    }
}
