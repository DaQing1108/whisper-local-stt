import Foundation

/// Places per-chunk transcription results on one session timeline.
///
/// - Chunks are applied strictly in the order they were registered (finalized). A result that
///   arrives early — e.g. a silent chunk judged instantly while the previous chunk is still
///   being transcribed — waits until every earlier chunk has been applied.
/// - A chunk advances the timeline by the Worker-reported audio length (`durationSeconds`,
///   from the WAV frame count). Whisper segment ends often overrun the real audio, so they are
///   only a fallback when the length is unknown.
/// - Segment times are clamped into the chunk (`0...duration`, `end >= start`) before the
///   chunk offset is added, so no segment spills into the next chunk.
struct ChunkTimeline: Sendable {
    struct Result: Sendable {
        let text: String
        let segments: [TranscriptionSegment]
        let durationSeconds: Double?
    }

    struct AppliedChunk: Equatable, Sendable {
        let url: URL
        let offset: Double
        let duration: Double
        let text: String
        let segments: [TranscriptionSegment]
    }

    private(set) var durationSeconds: Double = 0
    private var order: [URL] = []
    private var results: [URL: Result] = [:]

    /// Number of registered chunks still waiting for themselves or an earlier chunk.
    var waitingCount: Int { order.count }

    mutating func register(_ url: URL) {
        guard !order.contains(url) else { return }
        order.append(url)
    }

    /// Records a chunk's result and returns every chunk that can now be applied, in order.
    /// `fallbackDuration` is used only when the Worker did not report the audio length.
    mutating func complete(_ url: URL, result: Result, fallbackDuration: Double) -> [AppliedChunk] {
        register(url)
        results[url] = result
        var applied: [AppliedChunk] = []
        while let head = order.first, let ready = results.removeValue(forKey: head) {
            order.removeFirst()
            applied.append(apply(head, ready, fallbackDuration: fallbackDuration))
        }
        return applied
    }

    private mutating func apply(_ url: URL, _ result: Result, fallbackDuration: Double) -> AppliedChunk {
        let offset = durationSeconds
        let duration: Double
        if let reported = result.durationSeconds, reported.isFinite, reported >= 0 {
            duration = reported
        } else {
            duration = max(result.segments.map(\.end).max() ?? 0, fallbackDuration)
        }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var segments = result.segments.map { segment in
            let start = min(max(segment.start, 0), duration)
            let end = max(min(max(segment.end, 0), duration), start)
            return TranscriptionSegment(start: offset + start, end: offset + end, text: segment.text)
        }
        if segments.isEmpty, !text.isEmpty {
            segments = [TranscriptionSegment(start: offset, end: offset + duration, text: text)]
        }
        durationSeconds += duration
        return AppliedChunk(url: url, offset: offset, duration: duration, text: text, segments: segments)
    }
}
