import SwiftUI

/// Menu-bar title: red dot plus elapsed time (or 「轉錄中…」 while finishing).
struct MenuBarRecordingLabel: View {
    let board: CaptureStatusBoard

    var body: some View {
        let snapshot = board.snapshot
        HStack(spacing: 4) {
            Image(systemName: "circle.fill").foregroundStyle(.red)
            Text(MenuBarRules.label(phase: snapshot.phase, startedAt: snapshot.startedAt, now: board.now))
                .monospacedDigit()
        }
        .accessibilityLabel("Whisper 錄音中")
    }
}

/// Menu-bar panel shown while a capture is active. Reads only; stopping goes through the
/// board's `requestStop()`, i.e. the main window's own `.whisperToggleRecording` entry point.
struct MenuBarRecordingView: View {
    let board: CaptureStatusBoard
    @Environment(MixedAudioRecordingController.self) private var mixedAudioRecording
    @Environment(LiveRecordingController.self) private var liveRecording
    @Environment(StandardRecordingController.self) private var recording
    @Environment(AppSettingsStore.self) private var settings

    private static let panelWidth: CGFloat = 320

    var body: some View {
        let snapshot = board.snapshot
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "circle.fill").foregroundStyle(.red).font(.caption)
                Text(MenuBarRules.modeTitle(snapshot.mode)).font(.headline)
                Spacer()
                if let startedAt = snapshot.startedAt {
                    Text(MenuBarRules.elapsedText(from: startedAt, to: board.now))
                        .font(.body.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if let status = snapshot.statusText {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            if snapshot.phase == .recording { levelMeters(snapshot.mode) }
            ForEach(snapshot.silenceWarnings, id: \.self) { warning in
                Label(warning, systemImage: "speaker.slash").font(.caption).foregroundStyle(.orange)
            }
            Divider()
            recentTranscript(snapshot.mode)
            Divider()
            HStack {
                Button(MenuBarRules.stopButtonTitle(mode: snapshot.mode)) { board.requestStop() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(!MenuBarRules.stopEnabled(
                        phase: snapshot.phase, canStop: snapshot.canStop, stopRequested: board.stopRequested
                    ))
                Spacer()
                Button("打開 Whisper") { board.windowGuard.showMainWindow() }
            }
        }
        .padding(14)
        .frame(width: Self.panelWidth)
    }

    @ViewBuilder private func levelMeters(_ mode: AudioInputMode) -> some View {
        switch mode {
        case .mixed:
            TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                VStack(alignment: .leading, spacing: 4) {
                    if settings.includeMicrophoneInMixedMode {
                        meter("麥克風", level: mixedAudioRecording.microphoneLevel)
                    }
                    meter("系統", level: mixedAudioRecording.systemLevel)
                }
            }
        case .standard:
            meter("麥克風", level: recording.microphone.audioLevel)
        case .live:
            EmptyView()   // live mode exposes no input level
        }
    }

    private func meter(_ title: String, level: Double) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
            AudioWaveformView(level: level, isRecording: true)
        }
    }

    @ViewBuilder private func recentTranscript(_ mode: AudioInputMode) -> some View {
        if mode == .standard {
            Text("錄音結束後才會轉錄").font(.caption).foregroundStyle(.secondary)
        } else {
            let lines = MenuBarRules.recentLines(
                mode == .mixed ? mixedAudioRecording.transcriptText : liveRecording.transcriptText
            )
            if lines.isEmpty {
                Text("等待第一段轉錄…").font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.callout).lineLimit(2)
                    }
                }
            }
        }
    }
}
