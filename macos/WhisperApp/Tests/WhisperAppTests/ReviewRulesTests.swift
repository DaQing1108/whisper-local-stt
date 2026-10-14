import Foundation
import Testing
@testable import WhisperApp

private func segment(_ start: Double, _ end: Double, _ text: String, _ speaker: String? = nil) -> TranscriptionSegment {
    TranscriptionSegment(start: start, end: end, text: text, speaker: speaker)
}

struct TranscriptSearchTests {
    private let segments = [
        segment(0, 4, "今天討論 FTP 上傳"),
        segment(4, 8, "下一季的預算"),
        segment(8, 12, "ftp 的帳號要更新"),
        segment(12, 15, "其他事項", "Speaker A"),
    ]

    @Test func caseInsensitiveMatchesAndCount() {
        #expect(TranscriptSearch.matches(in: segments, query: "FTP") == [0, 2])
        #expect(TranscriptSearch.matches(in: segments, query: " ftp ") == [0, 2])
        #expect(TranscriptSearch.matches(in: segments, query: "speaker a") == [3])
        #expect(TranscriptSearch.matches(in: segments, query: "不存在") == [])
    }

    @Test func emptyQueryMatchesNothingAndHidesCounter() {
        #expect(TranscriptSearch.matches(in: segments, query: "").isEmpty)
        #expect(TranscriptSearch.matches(in: segments, query: "   ").isEmpty)
        #expect(TranscriptSearch.counterText(position: nil, matchCount: 0, query: "") == nil)
        #expect(TranscriptSearch.counterText(position: nil, matchCount: 0, query: "x") == "0／0")
        #expect(TranscriptSearch.counterText(position: 1, matchCount: 2, query: "ftp") == "2／2")
        #expect(TranscriptSearch.counterText(position: 5, matchCount: 2, query: "ftp") == "2／2")  // 舊位置超出時夾住
    }

    @Test func nextAndPreviousWrapAround() {
        #expect(TranscriptSearch.step(from: nil, matchCount: 3, forward: true) == 0)
        #expect(TranscriptSearch.step(from: nil, matchCount: 3, forward: false) == 2)
        #expect(TranscriptSearch.step(from: 2, matchCount: 3, forward: true) == 0)
        #expect(TranscriptSearch.step(from: 0, matchCount: 3, forward: false) == 2)
        #expect(TranscriptSearch.step(from: 1, matchCount: 3, forward: true) == 2)
        #expect(TranscriptSearch.step(from: 5, matchCount: 3, forward: true) == 0)
        #expect(TranscriptSearch.step(from: 0, matchCount: 0, forward: true) == nil)
    }
}

struct SpeakerColorTests {
    @Test func firstAppearanceOrderAndConsistency() {
        let indices = SpeakerColor.colorIndices(for: [
            segment(0, 1, "a", "Speaker B"), segment(1, 2, "b"), segment(2, 3, "c", "Speaker A"),
            segment(3, 4, "d", "Speaker B"), segment(4, 5, "e", "Speaker C"),
        ])
        #expect(indices == ["Speaker B": 0, "Speaker A": 1, "Speaker C": 2])
    }

    @Test func colorsCycleAfterPalette() {
        let speakers = (0..<8).map { "講者\($0)" }
        let indices = SpeakerColor.colorIndices(for: speakers.enumerated().map { segment(Double($0.offset), 1, "x", $0.element) })
        #expect(indices["講者6"] == 0)
        #expect(indices["講者7"] == 1)
        #expect(SpeakerColor.palette.count == 6)
        #expect(SpeakerColor.color(forIndex: 6) == SpeakerColor.color(forIndex: 0))
    }
}

struct PlaybackRulesTests {
    @Test func timeTextUnderAndOverOneHour() {
        #expect(PlaybackRules.timeText(0) == "0:00")
        #expect(PlaybackRules.timeText(65.9) == "1:05")
        #expect(PlaybackRules.timeText(3_599) == "59:59")
        #expect(PlaybackRules.timeText(3_600) == "1:00:00")
        #expect(PlaybackRules.timeText(6_773) == "1:52:53")
        #expect(PlaybackRules.timeText(-5) == "0:00")
        #expect(PlaybackRules.timeText(.nan) == "0:00")
    }

    @Test func timeToSegmentIndex() {
        let segments = [segment(2, 5, "a"), segment(5, 9, "b"), segment(12, 15, "c")]
        #expect(PlaybackRules.segmentIndex(at: 0, in: segments) == nil)     // 第一段之前
        #expect(PlaybackRules.segmentIndex(at: 2, in: segments) == 0)
        #expect(PlaybackRules.segmentIndex(at: 10, in: segments) == 1)      // 段落間空白：上一段
        #expect(PlaybackRules.segmentIndex(at: 99, in: segments) == 2)      // 最後一段之後
        #expect(PlaybackRules.segmentIndex(at: 3, in: []) == nil)
    }

    @Test func rateLabels() {
        #expect(PlaybackRules.rates == [1, 1.25, 1.5, 2])
        #expect(PlaybackRules.rates.map(PlaybackRules.rateLabel) == ["1x", "1.25x", "1.5x", "2x"])
    }

    @Test func playerIsCreatedWithChosenRate() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rate-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try PCM16WAVWriter(url: url)
        try writer.append(Data(count: 16_000 * 2))   // 1 秒靜音
        _ = try writer.finalize()

        let first = try PlaybackRules.makePlayer(url: url, rate: 1.5)
        #expect(first.enableRate)
        #expect(first.rate == 1.5)
        // Rebuilding the player (another record, or a seek to a different file) keeps the rate.
        let rebuilt = try PlaybackRules.makePlayer(url: url, rate: 1.5)
        #expect(rebuilt.rate == 1.5)
    }
}

@MainActor
struct ReviewHeaderRulesTests {
    @Test func dateLengthAndSpeakerCount() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 9, minute: 5))!
        #expect(ReviewHeaderRules.dateText(date, calendar: calendar) == "10/14 09:05")

        let short = TranscriptionHistoryEntry(
            audioPath: "/tmp/週會.wav", model: "base", language: "zh", text: "x",
            segments: [segment(0, 30, "a", "A"), segment(30, 95, "b", "B"), segment(95, 100, "c", "A")]
        )
        #expect(ReviewHeaderRules.durationSeconds(of: short) == 100)       // 無 durationSeconds：用最後一段結尾
        #expect(PlaybackRules.timeText(ReviewHeaderRules.durationSeconds(of: short)!) == "1:40")
        #expect(ReviewHeaderRules.speakerCount(short.segments) == 2)
        #expect(ReviewHeaderRules.defaultTitle(for: short) == "週會")

        let long = TranscriptionHistoryEntry(
            audioPath: "/tmp/b.wav", model: "base", language: "zh", text: "x",
            segments: [segment(0, 1, "a")], durationSeconds: 4_000
        )
        #expect(PlaybackRules.timeText(ReviewHeaderRules.durationSeconds(of: long)!) == "1:06:40")
        #expect(ReviewHeaderRules.speakerCount(long.segments) == 0)            // 0 → 標頭不顯示
    }

    @Test func nameOnlyRecordIsNotSummaryContent() {
        let id = UUID()
        #expect(!ReviewHeaderRules.hasSummaryContent(nil))
        #expect(!ReviewHeaderRules.hasSummaryContent(MeetingSummary(transcriptionID: id, meetingTitle: "名稱", status: .empty)))
        #expect(ReviewHeaderRules.hasSummaryContent(MeetingSummary(transcriptionID: id, meetingTitle: "名稱", status: .generating)))
        #expect(ReviewHeaderRules.hasSummaryContent(MeetingSummary(transcriptionID: id, meetingTitle: "名稱", generatedText: "摘要", status: .completed)))
        #expect(ReviewHeaderRules.hasSummaryContent(MeetingSummary(transcriptionID: id, meetingTitle: "名稱", status: .failed)))
    }
}
