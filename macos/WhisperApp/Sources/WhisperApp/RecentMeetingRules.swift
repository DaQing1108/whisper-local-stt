import Foundation

/// 「最近會議」menu in the review header.
enum RecentMeetingRules {
    static let limit = 5

    /// Newest first, excluding the record on screen.
    static func recent(
        _ entries: [TranscriptionHistoryEntry], excluding currentID: UUID?, limit: Int = limit
    ) -> [TranscriptionHistoryEntry] {
        Array(entries.filter { $0.id != currentID }.sorted { $0.completedAt > $1.completedAt }.prefix(limit))
    }

    /// 「名稱 · M/d HH:mm · 長度」— same naming rule as the header (saved name, else 會議 M/d HH:mm).
    static func label(
        for entry: TranscriptionHistoryEntry, savedTitle: String?, durationSeconds: TimeInterval?,
        calendar: Calendar = .current
    ) -> String {
        var parts = [
            savedTitle ?? ReviewHeaderRules.defaultTitle(for: entry, calendar: calendar),
            ReviewHeaderRules.dateText(entry.completedAt, calendar: calendar),
        ]
        if let durationSeconds { parts.append(PlaybackRules.timeText(durationSeconds)) }
        return parts.joined(separator: " · ")
    }
}
