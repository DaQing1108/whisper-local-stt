import Foundation

/// Tracks how long each mixed-mode input has been silent and when to warn the user.
/// Pure value type: feed it level samples with their timestamps; it never reads the clock.
struct InputSilenceMonitor: Equatable {
    /// Continuous silence before the warning appears.
    static let warningAfterSeconds: TimeInterval = 20
    /// Normalised (0–1) equivalent of the chunk silence detector's RMS threshold.
    static let silenceLevel = AudioChunkSilenceDetector.defaultThreshold / Double(Int16.max)

    private(set) var microphoneSilentSince: Date?
    private(set) var systemSilentSince: Date?

    /// `microphone` is nil when the microphone is not part of this recording, so it is never judged.
    mutating func record(microphone: Double?, system: Double, at date: Date) {
        microphoneSilentSince = Self.silentSince(microphoneSilentSince, level: microphone, at: date)
        systemSilentSince = Self.silentSince(systemSilentSince, level: system, at: date)
    }

    mutating func reset() {
        microphoneSilentSince = nil
        systemSilentSince = nil
    }

    func warnings(at now: Date) -> [String] {
        var messages: [String] = []
        if Self.isWarning(silentSince: microphoneSilentSince, now: now) { messages.append("麥克風持續沒有聲音") }
        if Self.isWarning(silentSince: systemSilentSince, now: now) { messages.append("系統音訊持續沒有聲音") }
        return messages
    }

    static func isWarning(silentSince: Date?, now: Date) -> Bool {
        guard let silentSince else { return false }
        return now.timeIntervalSince(silentSince) >= warningAfterSeconds
    }

    private static func silentSince(_ previous: Date?, level: Double?, at date: Date) -> Date? {
        guard let level, level < silenceLevel else { return nil }
        return previous ?? date
    }
}
