import AVFoundation
import SwiftUI

/// Transcript search over segments (reading mode). Case-insensitive; an empty query matches nothing.
enum TranscriptSearch {
    static func matches(in segments: [TranscriptionSegment], query: String) -> [Int] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return segments.indices.filter { index in
            let segment = segments[index]
            return segment.text.range(of: needle, options: .caseInsensitive) != nil
                || (segment.speaker?.range(of: needle, options: .caseInsensitive) != nil)
        }
    }

    /// Next/previous match position, wrapping around. `current` is a position in `matchCount`.
    static func step(from current: Int?, matchCount: Int, forward: Bool) -> Int? {
        guard matchCount > 0 else { return nil }
        guard let current, current >= 0, current < matchCount else { return forward ? 0 : matchCount - 1 }
        return (current + (forward ? 1 : -1) + matchCount) % matchCount
    }

    /// 「n／總數」, or nil when there is no query.
    static func counterText(position: Int?, matchCount: Int, query: String) -> String? {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard matchCount > 0 else { return "0／0" }
        let current = min(max(position ?? 0, 0), matchCount - 1)
        return "\(current + 1)／\(matchCount)"
    }
}

/// Speaker colours: assigned in order of first appearance, cycling through system colours.
enum SpeakerColor {
    static let palette: [Color] = [.blue, .purple, .orange, .teal, .pink, .indigo]

    static func colorIndices(for segments: [TranscriptionSegment]) -> [String: Int] {
        var indices: [String: Int] = [:]
        for speaker in segments.compactMap(\.speaker) where indices[speaker] == nil {
            indices[speaker] = indices.count % palette.count
        }
        return indices
    }

    static func color(forIndex index: Int) -> Color { palette[index % palette.count] }
}

/// Playback bar rules: time text, time → segment, rates.
enum PlaybackRules {
    static let rates: [Float] = [1, 1.25, 1.5, 2]

    /// `M:SS` under an hour, otherwise `H:MM:SS`.
    static func timeText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.isFinite ? seconds.rounded(.down) : 0))
        let hours = total / 3_600, minutes = (total / 60) % 60, secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// The last segment starting at or before `time`; nil before the first segment.
    static func segmentIndex(at time: TimeInterval, in segments: [TranscriptionSegment]) -> Int? {
        segments.lastIndex { $0.start <= time }
    }

    static func rateLabel(_ rate: Float) -> String {
        rate == rate.rounded() ? "\(Int(rate))x" : "\(rate)x"
    }

    /// Every player is created through here so the chosen rate survives a rebuilt player.
    static func makePlayer(url: URL, rate: Float) throws -> AVAudioPlayer {
        let player = try AVAudioPlayer(contentsOf: url)
        player.enableRate = true
        player.rate = rate
        return player
    }
}

/// Review-page header facts.
enum ReviewHeaderRules {
    static func dateText(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
        return String(format: "%d/%d %02d:%02d", parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0)
    }

    /// Recording length: stored duration, else the end of the last segment.
    static func durationSeconds(of entry: TranscriptionHistoryEntry) -> TimeInterval? {
        entry.durationSeconds ?? entry.segments.map(\.end).max()
    }

    /// Distinct speakers in the segments; 0 means "don't show".
    static func speakerCount(_ segments: [TranscriptionSegment]) -> Int {
        Set(segments.compactMap(\.speaker)).count
    }

    /// Fallback name when none was saved — the existing rule (audio file name).
    static func defaultTitle(for entry: TranscriptionHistoryEntry) -> String {
        URL(fileURLWithPath: entry.audioPath).deletingPathExtension().lastPathComponent
    }

    /// A name-only record (status .empty, no text) is not a summary for summary-tab purposes.
    static func hasSummaryContent(_ summary: MeetingSummary?) -> Bool {
        guard let summary else { return false }
        return summary.status != .empty || !summary.effectiveText.isEmpty
    }
}
