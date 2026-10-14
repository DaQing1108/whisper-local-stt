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

    @Test func legacyFileAndBatchAddedFileRemainMutuallyReadable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("vocabulary.json")
        let legacyID = UUID()
        // Exactly the on-disk shape written before batch add existed.
        let legacy = #"[{"id":"\#(legacyID.uuidString)","value":"VIA","isEnabled":false}]"#
        try Data(legacy.utf8).write(to: url)

        let store = VocabularyStore(fileURL: url)
        #expect(store.terms == [VocabularyTerm(id: legacyID, value: "VIA", isEnabled: false)])
        try store.addAll(["via", " FTP ", "KM", "ftp", ""])

        let raw = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        #expect(raw.allSatisfy { Set($0.keys) == ["id", "value", "isEnabled"] })
        #expect(raw.map { $0["value"] as? String } == ["VIA", "FTP", "KM"])
        #expect(raw.first?["isEnabled"] as? Bool == false)
        let restored = VocabularyStore(fileURL: url)
        #expect(restored.terms.map(\.value) == ["VIA", "FTP", "KM"])
        #expect(restored.activeTermsText == "FTP, KM")
    }
}
