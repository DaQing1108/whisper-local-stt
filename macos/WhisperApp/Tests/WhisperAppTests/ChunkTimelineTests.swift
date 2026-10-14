import Foundation
import Testing
@testable import WhisperApp

/// Deterministic generator so the 200-chunk simulations are reproducible.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

/// One simulated chunk: real length 8–30s, Whisper segments whose ends overrun it by 0–3s.
struct SimulatedChunk {
    let duration: Double
    let segments: [TranscriptionSegment]

    static func make(count: Int, seed: UInt64) -> [SimulatedChunk] {
        var rng = SeededGenerator(seed: seed)
        return (0..<count).map { index in
            let duration = Double.random(in: 8...30, using: &rng)
            let pieces = Int.random(in: 1...4, using: &rng)
            let step = duration / Double(pieces)
            let segments = (0..<pieces).map { piece in
                let start = Double(piece) * step
                let overrun = piece == pieces - 1 ? Double.random(in: 0...3, using: &rng) : 0
                return TranscriptionSegment(start: start, end: start + step + overrun, text: "合成句\(index)-\(piece)")
            }
            return SimulatedChunk(duration: duration, segments: segments)
        }
    }
}

struct ChunkTimelineTests {
    private func url(_ index: Int) -> URL { URL(fileURLWithPath: "/tmp/chunk-\(index).wav") }

    @Test func reportedDurationDrivesTimelineDespiteSegmentOverrun() {
        let chunks = SimulatedChunk.make(count: 200, seed: 42)
        var timeline = ChunkTimeline()
        var applied: [ChunkTimeline.AppliedChunk] = []
        for (index, chunk) in chunks.enumerated() {
            timeline.register(url(index))
            applied += timeline.complete(
                url(index),
                result: .init(text: "", segments: chunk.segments, durationSeconds: chunk.duration),
                fallbackDuration: 15
            )
        }

        let realTotal = chunks.map(\.duration).reduce(0, +)
        #expect(abs(timeline.durationSeconds - realTotal) < 0.01)
        let segments = applied.flatMap(\.segments)
        for chunk in applied {
            #expect(chunk.segments.allSatisfy { $0.start >= chunk.offset && $0.end <= chunk.offset + chunk.duration })
        }
        #expect(zip(segments, segments.dropFirst()).allSatisfy { $0.start <= $1.start })
        #expect(segments.allSatisfy { $0.end >= $0.start })
    }

    @Test func earlyResultWaitsForEarlierChunk() {
        var timeline = ChunkTimeline()
        timeline.register(url(1))
        timeline.register(url(2))

        let silentFirst = timeline.complete(url(2), result: .init(text: "", segments: [], durationSeconds: 5), fallbackDuration: 15)
        #expect(silentFirst.isEmpty)
        #expect(timeline.durationSeconds == 0)
        #expect(timeline.waitingCount == 2)

        let both = timeline.complete(
            url(1),
            result: .init(text: "第一段", segments: [TranscriptionSegment(start: 0, end: 12, text: "第一段")], durationSeconds: 10),
            fallbackDuration: 15
        )
        #expect(both.map(\.url) == [url(1), url(2)])
        #expect(both.map(\.offset) == [0, 10])
        #expect(both[0].segments == [TranscriptionSegment(start: 0, end: 10, text: "第一段")])
        #expect(timeline.durationSeconds == 15)
        #expect(timeline.waitingCount == 0)
    }

    @Test func missingDurationKeepsFallbackBehaviour() {
        var timeline = ChunkTimeline()
        let overrun = timeline.complete(
            url(1), result: .init(text: "", segments: [TranscriptionSegment(start: 0, end: 18, text: "a")], durationSeconds: nil),
            fallbackDuration: 15
        )
        #expect(overrun[0].duration == 18)
        let short = timeline.complete(url(2), result: .init(text: "只有文字", segments: [], durationSeconds: nil), fallbackDuration: 15)
        #expect(short[0].duration == 15)
        #expect(short[0].segments == [TranscriptionSegment(start: 18, end: 33, text: "只有文字")])
    }

    @Test func invertedOrNegativeSegmentTimesAreClamped() {
        var timeline = ChunkTimeline()
        let applied = timeline.complete(
            url(1),
            result: .init(text: "", segments: [
                TranscriptionSegment(start: -1, end: 2, text: "a"),
                TranscriptionSegment(start: 6, end: 4, text: "b"),
                TranscriptionSegment(start: 12, end: 14, text: "c"),
            ], durationSeconds: 10),
            fallbackDuration: 15
        )
        #expect(applied[0].segments.map(\.start) == [0, 6, 10])
        #expect(applied[0].segments.map(\.end) == [2, 6, 10])
    }
}
