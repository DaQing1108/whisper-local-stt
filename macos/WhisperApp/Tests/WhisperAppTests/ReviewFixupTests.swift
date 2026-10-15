import Foundation
import Testing
@testable import WhisperApp

@MainActor
struct ReviewFixupTests {
    private var taipei: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return calendar
    }

    private func entry(at components: DateComponents, durationSeconds: Double? = nil,
                       segments: [TranscriptionSegment] = [], audioPath: String = "/tmp/mixed-audio-session-B354DC6E.wav") -> TranscriptionHistoryEntry {
        TranscriptionHistoryEntry(
            completedAt: taipei.date(from: components)!, audioPath: audioPath, model: "base", language: "zh",
            text: "x", segments: segments, durationSeconds: durationSeconds
        )
    }

    // AC-1
    @Test func defaultTitleUsesCompletionTimeNotFileName() {
        let afternoon = entry(at: DateComponents(year: 2026, month: 10, day: 14, hour: 12, minute: 57))
        #expect(ReviewHeaderRules.defaultTitle(for: afternoon, calendar: taipei) == "會議 10/14 12:57")
        let morning = entry(at: DateComponents(year: 2027, month: 1, day: 3, hour: 9, minute: 5))
        #expect(ReviewHeaderRules.defaultTitle(for: morning, calendar: taipei) == "會議 1/3 09:05")  // 個位數、跨年不顯示年份
        #expect(!ReviewHeaderRules.defaultTitle(for: morning, calendar: taipei).contains("mixed-audio-session"))
    }

    @Test func userTitleWinsOverDefault() {
        #expect(ReviewHeaderRules.titleToSave(typed: "產品週會", savedTitle: nil, defaultTitle: "會議 10/14 12:57") == "產品週會")
        #expect(ReviewHeaderRules.titleToSave(typed: "新名稱", savedTitle: "產品週會", defaultTitle: "會議 10/14 12:57") == "新名稱")
        #expect(ReviewHeaderRules.titleToSave(typed: "  ", savedTitle: "產品週會", defaultTitle: "會議 10/14 12:57") == nil)
    }

    // AC-2: browsing records (header shows the default or the saved name, untouched) writes nothing.
    @Test func browsingRecordsCreatesNoSummaryRecords() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingSummaryStore(fileURL: directory.appendingPathComponent("meeting-summaries.json"))
        let named = entry(at: DateComponents(year: 2026, month: 10, day: 13, hour: 10, minute: 0))
        try store.saveTitle(transcriptionID: named.id, title: "mixed-audio-session-OLD")  // 舊版存下的檔名式名稱
        let entries = [named] + (1...4).map { entry(at: DateComponents(year: 2026, month: 10, day: $0, hour: 9, minute: 30)) }
        let before = store.summaries

        for viewed in entries {
            let saved = store.summary(for: viewed.id)?.meetingTitle
            let defaultTitle = ReviewHeaderRules.defaultTitle(for: viewed, calendar: taipei)
            let shown = saved ?? defaultTitle   // what loadSummaryWorkspace puts in the header
            if let title = ReviewHeaderRules.titleToSave(typed: shown, savedTitle: saved, defaultTitle: defaultTitle) {
                try store.saveTitle(transcriptionID: viewed.id, title: title)
            }
        }

        #expect(store.summaries == before)
        #expect(store.summary(for: named.id)?.meetingTitle == "mixed-audio-session-OLD")  // 已存名稱不被改
    }

    // AC-3
    @Test func realAudioLengthWinsThenStoredThenLastSegment() {
        let segments = [TranscriptionSegment(start: 0, end: 50, text: "a")]
        let stale = entry(at: DateComponents(year: 2026, month: 10, day: 14, hour: 1), durationSeconds: 7_150, segments: segments)
        #expect(ReviewHeaderRules.durationSeconds(of: stale, actualAudioSeconds: 6_773) == 6_773)
        #expect(PlaybackRules.timeText(ReviewHeaderRules.durationSeconds(of: stale, actualAudioSeconds: 6_773)!) == "1:52:53")
        #expect(ReviewHeaderRules.durationSeconds(of: stale, actualAudioSeconds: nil) == 7_150)
        let noStored = entry(at: DateComponents(year: 2026, month: 10, day: 14, hour: 1), segments: segments)
        #expect(ReviewHeaderRules.durationSeconds(of: noStored, actualAudioSeconds: nil) == 50)
        #expect(ReviewHeaderRules.durationSeconds(of: entry(at: DateComponents(year: 2026, month: 1, day: 1)), actualAudioSeconds: nil) == nil)
    }

    @Test func exportFileNameIsSafe() {
        #expect(ReviewHeaderRules.fileNameStem(for: "會議 10/14 12:57") == "會議 10-14 12-57")
        #expect(ReviewHeaderRules.fileNameStem(for: "產品週會") == "產品週會")
        #expect(ReviewHeaderRules.fileNameStem(for: " / ") == "-")
        #expect(ReviewHeaderRules.fileNameStem(for: "  ") == "transcript")
    }

    // AC-5: a ~200 MB WAV whose data is a sparse hole — reading it would take far longer than a
    // header read, and the length must come from the header's data size.
    @Test func audioLengthReadsHeaderOnly() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("long-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let dataBytes: UInt32 = 200 * 1_024 * 1_024
        var header = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        header.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36) + dataBytes)
        header.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(16_000)); append(UInt32(32_000)); append(UInt16(2)); append(UInt16(16))
        header.append(contentsOf: Array("data".utf8)); append(dataBytes)
        FileManager.default.createFile(atPath: url.path, contents: header)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(header.count) + UInt64(dataBytes))   // sparse: no data written
        try handle.close()

        let clock = ContinuousClock()
        var seconds: TimeInterval?
        let elapsed = clock.measure { seconds = ReviewHeaderRules.audioFileDuration(atPath: url.path) }

        #expect(seconds.map { abs($0 - Double(dataBytes) / 32_000) < 0.01 } == true)   // 6553.6 秒
        #expect(elapsed < .milliseconds(500))
        #expect(ReviewHeaderRules.audioFileDuration(atPath: "/tmp/does-not-exist-\(UUID()).wav") == nil)
    }

    @Test func perChunkAudioIsNotTreatedAsSessionLength() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for folder in ["LiveChunks", "MixedAudioChunks", "Sessions"] {
            let directory = root.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let writer = try PCM16WAVWriter(url: directory.appendingPathComponent("a.wav"))
            try writer.append(Data(count: 32_000 * 15))   // 15 秒
            _ = try writer.finalize()
        }
        #expect(ReviewHeaderRules.sessionAudioDuration(atPath: root.appendingPathComponent("LiveChunks/a.wav").path) == nil)
        #expect(ReviewHeaderRules.sessionAudioDuration(atPath: root.appendingPathComponent("MixedAudioChunks/a.wav").path) == nil)
        #expect(ReviewHeaderRules.sessionAudioDuration(atPath: root.appendingPathComponent("Sessions/a.wav").path) == 15)
    }
}
