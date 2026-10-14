import Foundation
import Testing
@testable import WhisperApp

/// Synthetic vocabulary only — no real names or user data.
@MainActor
struct VocabularyPriorityTests {
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        func advance(days: Double) { now = now.addingTimeInterval(days * 86_400) }
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeStore(in directory: URL, clock: Clock) -> VocabularyStore {
        VocabularyStore(fileURL: directory.appendingPathComponent("vocabulary.json"), now: { clock.now })
    }

    @Test func mostRecentlyActiveTermsGoLast() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock()
        let store = makeStore(in: directory, clock: clock)
        try store.add("Zyntrix")       // 30 天前加入、從未出現
        try store.add("Quorvane")      // 30 天前加入、昨天出現
        clock.advance(days: 29)
        store.recordSeen(in: "昨天的會議提到 Quorvane 的進度", at: clock.now)
        clock.advance(days: 1)
        try store.add("Plexidon")      // 今天剛加入

        #expect(store.activeTermsText == "Zyntrix, Quorvane, Plexidon")
        #expect(store.terms.map(\.value) == ["Zyntrix", "Quorvane", "Plexidon"])  // 清單顯示順序不變

        clock.advance(days: 1)
        store.recordSeen(in: "zyntrix 又出現了", at: clock.now)
        #expect(store.activeTermsText == "Quorvane, Plexidon, Zyntrix")
    }

    @Test func legacyTermsWithoutUsageKeepListOrderStably() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = (0..<3).map { #"{"id":"\#(UUID().uuidString)","value":"Legacy\#($0)","isEnabled":true}"# }
        try Data("[\(legacy.joined(separator: ","))]".utf8)
            .write(to: directory.appendingPathComponent("vocabulary.json"))
        let clock = Clock()
        let store = makeStore(in: directory, clock: clock)

        #expect(store.activeTermsText == "Legacy0, Legacy1, Legacy2")
        #expect(store.activeTermsText == store.activeTermsText)
        try store.add("Zyntrix")
        #expect(store.activeTermsText == "Legacy0, Legacy1, Legacy2, Zyntrix")
        store.recordSeen(in: "legacy0 出現", at: clock.now.addingTimeInterval(1))
        #expect(store.activeTermsText == "Legacy1, Legacy2, Zyntrix, Legacy0")
        // Reload: order is reproduced from vocabulary-usage.json.
        #expect(makeStore(in: directory, clock: clock).activeTermsText == "Legacy1, Legacy2, Zyntrix, Legacy0")
    }

    @Test func disabledTermsAreExcludedFromPromptOrder() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(in: directory, clock: Clock())
        try store.addAll(["Zyntrix", "Quorvane"])
        try store.toggle(store.terms[0])

        #expect(store.promptOrderedActiveTerms.map(\.value) == ["Quorvane"])
    }

    @Test func recordedTranscriptUpdatesLastSeenWithASCIIBoundaries() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock()
        let store = makeStore(in: directory, clock: clock)
        try store.addAll(["KM", "FTP", "量子平台", "Unseen"])
        let history = TranscriptionHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        history.resultRecordedHandler = { [weak store] text, date in store?.recordSeen(in: text, at: date) }
        let byValue = { (value: String) in store.terms.first { $0.value == value }! }

        let entry = try history.recordCompleted(
            audioURL: URL(fileURLWithPath: "/tmp/a.wav"), model: "base", language: "zh",
            text: "請把檔案放到 KMS，再用 ftp 傳到量子平台"
        )

        #expect(store.usage.usage[byValue("KM").id]?.lastSeenAt == nil)        // KM 不命中 KMS
        #expect(store.usage.usage[byValue("FTP").id]?.lastSeenAt == entry.completedAt)  // 不分大小寫
        #expect(store.usage.usage[byValue("量子平台").id]?.lastSeenAt == entry.completedAt)
        #expect(store.usage.usage[byValue("Unseen").id]?.lastSeenAt == nil)

        try history.updateText(id: entry.id, text: "手動編輯提到 Unseen")       // 手動編輯不算出現
        #expect(store.usage.usage[byValue("Unseen").id]?.lastSeenAt == nil)
        _ = try history.updateResult(id: entry.id, text: "重新轉錄：KM 與 Unseen", segments: [], durationSeconds: nil)
        #expect(store.usage.usage[byValue("KM").id]?.lastSeenAt != nil)
        #expect(store.usage.usage[byValue("Unseen").id]?.lastSeenAt != nil)
    }

    @Test func sightingsWithinGranularityDoNotRewriteAndRemoveForgetsUsage() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock()
        let store = makeStore(in: directory, clock: clock)
        try store.add("Zyntrix")
        let id = store.terms[0].id
        store.recordSeen(in: "Zyntrix", at: clock.now)
        let first = store.usage.usage[id]?.lastSeenAt

        store.recordSeen(in: "Zyntrix", at: clock.now.addingTimeInterval(30))
        #expect(store.usage.usage[id]?.lastSeenAt == first)
        store.recordSeen(in: "Zyntrix", at: clock.now.addingTimeInterval(-3_600))
        #expect(store.usage.usage[id]?.lastSeenAt == first)      // 不倒退
        store.recordSeen(in: "Zyntrix", at: clock.now.addingTimeInterval(61))
        #expect(store.usage.usage[id]?.lastSeenAt == clock.now.addingTimeInterval(61))

        try store.remove(store.terms[0])
        #expect(store.usage.usage[id] == nil)
    }

    @Test func matcherBoundaries() {
        #expect(VocabularyTermMatcher.contains("KM, ok", term: "KM"))
        #expect(VocabularyTermMatcher.contains("放入km。", term: "KM"))
        #expect(!VocabularyTermMatcher.contains("KMS 系統", term: "KM"))
        #expect(!VocabularyTermMatcher.contains("XKM", term: "KM"))
        #expect(VocabularyTermMatcher.contains("XKM 與 KM", term: "KM"))
        #expect(VocabularyTermMatcher.contains("新量子平台上線", term: "量子平台"))
        #expect(!VocabularyTermMatcher.contains("任何文字", term: "  "))
    }

    @Test func backfillRunsOnceFromHistory() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacyID = UUID()
        try Data(#"[{"id":"\#(legacyID.uuidString)","value":"Zyntrix","isEnabled":true}]"#.utf8)
            .write(to: directory.appendingPathComponent("vocabulary.json"))
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = Date(timeIntervalSince1970: 1_700_500_000)
        let history = [
            TranscriptionHistoryEntry(completedAt: newer, audioPath: "/tmp/b.wav", model: "base", language: "zh", text: "提到 Zyntrix"),
            TranscriptionHistoryEntry(completedAt: older, audioPath: "/tmp/a.wav", model: "base", language: "zh", text: "zyntrix 第一次"),
        ]
        let clock = Clock()

        let first = makeStore(in: directory, clock: clock)
        #expect(first.usage.needsBackfill)
        first.backfillUsageIfNeeded(from: history)
        #expect(first.usage.usage[legacyID]?.lastSeenAt == newer)
        #expect(!first.usage.needsBackfill)

        let second = makeStore(in: directory, clock: clock)
        #expect(!second.usage.needsBackfill)
        second.backfillUsageIfNeeded(from: [
            TranscriptionHistoryEntry(completedAt: Date(timeIntervalSince1970: 1_750_000_000), audioPath: "/tmp/c.wav",
                                      model: "base", language: "zh", text: "Zyntrix"),
        ])
        #expect(second.usage.usage[legacyID]?.lastSeenAt == newer)  // 不重掃
    }

    @Test func usageFileIsUUIDKeyedObjectAndVocabularyFormatUnchanged() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(in: directory, clock: Clock())
        try store.add("Zyntrix")
        let id = store.terms[0].id

        let usageRoot = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: directory.appendingPathComponent("vocabulary-usage.json"))
        ) as? [String: Any])
        let terms = try #require(usageRoot["terms"] as? [String: [String: Any]])
        #expect(terms[id.uuidString]?["addedAt"] is String)
        let vocabulary = try #require(JSONSerialization.jsonObject(
            with: Data(contentsOf: directory.appendingPathComponent("vocabulary.json"))
        ) as? [[String: Any]])
        #expect(vocabulary.allSatisfy { Set($0.keys) == ["id", "value", "isEnabled"] })
    }

    @Test func corruptOrUnwritableUsageNeverBlocksVocabulary() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("not json".utf8).write(to: directory.appendingPathComponent("vocabulary-usage.json"))
        let corrupt = makeStore(in: directory, clock: Clock())
        #expect(corrupt.usage.loadError != nil)
        try corrupt.add("Zyntrix")
        #expect(corrupt.terms.map(\.value) == ["Zyntrix"])

        let blocker = directory.appendingPathComponent("blocker")
        try Data().write(to: blocker)
        let unwritable = VocabularyStore(
            fileURL: directory.appendingPathComponent("vocabulary-2.json"),
            usage: VocabularyUsageStore(fileURL: blocker.appendingPathComponent("usage.json"))
        )
        try unwritable.add("Quorvane")
        #expect(unwritable.terms.map(\.value) == ["Quorvane"])
        #expect(unwritable.usage.writeError != nil)
    }

    @Test func notAppliedFollowsPromptOrderNotListOrder() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = Clock()
        let store = makeStore(in: directory, clock: clock)
        try store.addAll(["Zyntrix", "Quorvane", "Plexidon"])
        clock.advance(days: 1)
        store.recordSeen(in: "Zyntrix 最近出現", at: clock.now)   // 清單第 1 個 → prompt 尾端
        #expect(store.activeTermsText == "Quorvane, Plexidon, Zyntrix")

        let provider = DroppingProvider(dropped: ["Quorvane"])
        let budget = VocabularyBudgetController(provider: provider, debounce: .milliseconds(10))
        budget.scheduleRefresh(VocabularyBudgetInputs(
            modelName: "base", domain: "general", extraTerms: store.activeTermsText, isWorkerReady: true
        ))
        await budget.pendingRefresh?.value

        let dropped = budget.droppedTermIDs(in: store.promptOrderedActiveTerms)
        #expect(dropped == [store.terms[1].id])          // Quorvane（prompt 開頭）
        #expect(!dropped.contains(store.terms[0].id))     // 不是清單第 1 個
    }
}

@MainActor
private final class DroppingProvider: PromptBudgetProviding {
    let dropped: [String]
    init(dropped: [String]) { self.dropped = dropped }
    func promptBudget(modelName: String, domain: String, extraTerms: String) async throws -> PromptBudget {
        PromptBudget(tokens: 230, limit: 223, droppedTerms: dropped, available: true)
    }
}
