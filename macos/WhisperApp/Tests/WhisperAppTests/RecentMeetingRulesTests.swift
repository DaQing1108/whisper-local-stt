import Foundation
import Testing
@testable import WhisperApp

struct RecentMeetingRulesTests {
    private var taipei: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return calendar
    }

    private func entry(day: Int, hour: Int = 10) -> TranscriptionHistoryEntry {
        TranscriptionHistoryEntry(
            completedAt: taipei.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: 5))!,
            audioPath: "/tmp/\(day).wav", model: "base", language: "zh", text: "x"
        )
    }

    // AC-B1
    @Test func newestFirstExcludingCurrentLimitedToFive() {
        let entries = [entry(day: 3), entry(day: 9), entry(day: 1), entry(day: 7), entry(day: 5), entry(day: 8), entry(day: 2)]
        let current = entries[1]   // day 9
        let recent = RecentMeetingRules.recent(entries, excluding: current.id)
        #expect(recent.count == 5)
        #expect(!recent.contains { $0.id == current.id })
        #expect(recent.map(\.audioPath) == ["/tmp/8.wav", "/tmp/7.wav", "/tmp/5.wav", "/tmp/3.wav", "/tmp/2.wav"])
    }

    @Test func fewerThanFiveAndEmpty() {
        let entries = [entry(day: 1), entry(day: 2)]
        #expect(RecentMeetingRules.recent(entries, excluding: nil).map(\.audioPath) == ["/tmp/2.wav", "/tmp/1.wav"])
        #expect(RecentMeetingRules.recent(entries, excluding: entries[1].id).map(\.audioPath) == ["/tmp/1.wav"])
        #expect(RecentMeetingRules.recent([], excluding: nil).isEmpty)
    }

    // AC-B2: same naming rule as the header.
    @Test func labelFollowsHeaderNaming() {
        let unnamed = entry(day: 14, hour: 12)
        #expect(RecentMeetingRules.label(for: unnamed, savedTitle: nil, durationSeconds: 6_773, calendar: taipei)
                == "會議 10/14 12:05 · 10/14 12:05 · 1:52:53")
        #expect(RecentMeetingRules.label(for: unnamed, savedTitle: "產品週會", durationSeconds: 95, calendar: taipei)
                == "產品週會 · 10/14 12:05 · 1:35")
        #expect(RecentMeetingRules.label(for: unnamed, savedTitle: "產品週會", durationSeconds: nil, calendar: taipei)
                == "產品週會 · 10/14 12:05")
    }
}
