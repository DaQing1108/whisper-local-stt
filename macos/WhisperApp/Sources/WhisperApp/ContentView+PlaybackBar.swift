import AVFoundation
import SwiftUI

/// Review-page playback: play/pause, position, scrubbing, speed. Segment highlighting while
/// playing keeps the existing polling logic.
extension ContentView {
    @ViewBuilder func playbackBar(_ entry: TranscriptionHistoryEntry) -> some View {
        if FileManager.default.fileExists(atPath: entry.audioPath) {
            // Refresh position only while playing; scrubbing and play/pause redraw via state changes.
            TimelineView(.animation(minimumInterval: 0.25, paused: audioPlayer?.isPlaying != true)) { _ in
                playbackControls(entry)
            }
        } else {
            HStack {
                Image(systemName: "speaker.slash")
                Text("找不到錄音檔").font(.caption)
                Spacer()
            }
            .foregroundStyle(.secondary)
        }
    }

    private func playbackControls(_ entry: TranscriptionHistoryEntry) -> some View {
        let isPlaying = audioPlayer?.isPlaying == true
        let duration = max(audioPlayer?.duration ?? ReviewHeaderRules.durationSeconds(of: entry) ?? 0, 0)
        let position = min(scrubTime ?? audioPlayer?.currentTime ?? 0, duration)
        return HStack(spacing: 10) {
            Button { togglePlayback(entry) } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill").frame(width: 16)
            }
            .buttonStyle(.bordered)
            .help(isPlaying ? "暫停" : "播放")
            Text(PlaybackRules.timeText(position)).font(.caption.monospacedDigit())
            Slider(
                value: Binding(
                    get: { position },
                    set: { time in
                        // While dragging only the display (and highlight) follow; seek on release.
                        scrubTime = time
                        playingSegmentIndex = PlaybackRules.segmentIndex(at: time, in: entry.segments)
                    }
                ),
                in: 0...max(duration, 0.1),
                onEditingChanged: { isEditing in
                    guard !isEditing, let time = scrubTime else { return }
                    seek(toTime: time, in: entry)
                    scrubTime = nil
                }
            )
            .accessibilityLabel("播放位置")
            Text(PlaybackRules.timeText(duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Picker("播放速度", selection: Binding(
                get: { playbackRate },
                set: { rate in playbackRate = rate; audioPlayer?.rate = rate }
            )) {
                ForEach(PlaybackRules.rates, id: \.self) { Text(PlaybackRules.rateLabel($0)).tag($0) }
            }
            .labelsHidden()
            .frame(width: 72)
        }
    }

    func togglePlayback(_ entry: TranscriptionHistoryEntry) {
        do {
            if audioPlayer?.isPlaying == true { audioPlayer?.pause(); return }
            if audioPlayer == nil {
                audioPlayer = try PlaybackRules.makePlayer(url: URL(fileURLWithPath: entry.audioPath), rate: playbackRate)
            }
            audioPlayer?.play()
            startPlaybackPolling(entry)
            errorMessage = nil
        } catch { errorMessage = "無法播放來源音訊：\(error.localizedDescription)" }
    }

    func seek(to segment: TranscriptionSegment, index: Int, in entry: TranscriptionHistoryEntry) {
        do {
            try preparePlayer(for: entry)
            audioPlayer?.currentTime = segment.start
            audioPlayer?.play()
            playingSegmentIndex = index
            errorMessage = nil
            startPlaybackPolling(entry)
        } catch { errorMessage = "無法播放來源音訊：\(error.localizedDescription)" }
    }

    /// Scrubber release: jump without changing play/pause state.
    func seek(toTime time: TimeInterval, in entry: TranscriptionHistoryEntry) {
        do {
            try preparePlayer(for: entry)
            audioPlayer?.currentTime = time
            playingSegmentIndex = PlaybackRules.segmentIndex(at: time, in: entry.segments)
            errorMessage = nil
        } catch { errorMessage = "無法播放來源音訊：\(error.localizedDescription)" }
    }

    private func preparePlayer(for entry: TranscriptionHistoryEntry) throws {
        let audioURL = URL(fileURLWithPath: entry.audioPath)
        if audioPlayer == nil || audioPlayer?.url != audioURL {
            audioPlayer = try PlaybackRules.makePlayer(url: audioURL, rate: playbackRate)
        }
    }

    func startPlaybackPolling(_ entry: TranscriptionHistoryEntry) {
        stopPlaybackPolling()
        playbackPollTimer = Timer.scheduledTimer(withTimeInterval: Self.playbackPollInterval, repeats: true) { _ in
            Task { @MainActor in
                guard let player = audioPlayer, player.isPlaying else {
                    stopPlaybackPolling()
                    return
                }
                let currentTime = player.currentTime
                // Segments may have gaps (silence with no transcript); when currentTime falls in
                // a gap, deliberately keep the previous highlight rather than clearing it.
                if let match = entry.segments.firstIndex(where: { currentTime >= $0.start && currentTime < $0.end }) {
                    playingSegmentIndex = match
                }
            }
        }
    }

    func stopPlaybackPolling() {
        playbackPollTimer?.invalidate()
        playbackPollTimer = nil
    }
}
