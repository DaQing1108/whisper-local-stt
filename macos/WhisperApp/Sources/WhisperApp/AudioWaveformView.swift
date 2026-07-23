import SwiftUI

/// Purely visual audio-level indicator for the compact capture control bar.
/// Takes only `level`/`isRecording` as input — reads no controller/store state itself.
struct AudioWaveformView: View {
    let level: Double
    let isRecording: Bool

    private static let barCount = 20

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.08, paused: !isRecording)) { timeline in
            Canvas { context, size in
                guard isRecording else { return }
                let barWidth = size.width / CGFloat(Self.barCount)
                let clampedLevel = max(0, min(1, level))
                for index in 0..<Self.barCount {
                    let phase = timeline.date.timeIntervalSinceReferenceDate * 6 + Double(index) * 0.35
                    let wobble = (sin(phase) + 1) / 2
                    let amplitude = max(0.08, clampedLevel) * wobble
                    let barHeight = size.height * CGFloat(0.15 + amplitude * 0.85)
                    let rect = CGRect(
                        x: CGFloat(index) * barWidth + barWidth * 0.15,
                        y: (size.height - barHeight) / 2,
                        width: barWidth * 0.7,
                        height: barHeight
                    )
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: barWidth * 0.35),
                        with: .color(DaylightPalette.accentRecord)
                    )
                }
            }
        }
        .frame(height: 28)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Audio input level")
        .accessibilityValue(isRecording ? "\(Int(max(0, min(1, level)) * 100)) percent" : "Not recording")
    }
}
