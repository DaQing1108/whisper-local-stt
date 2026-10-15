import Foundation

/// Where a capture is in its life: nothing, capturing audio, or finishing (stop requested and the
/// last chunks are still being transcribed into the session).
enum CapturePhase: Equatable, Sendable {
    case idle
    case recording
    case finishing

    var isActive: Bool { self != .idle }

    /// Standard mode transcribes the whole file after stop; that job counts as finishing.
    /// Permission / pre-start states are not a capture yet (nothing to stop or protect).
    static func standard(_ state: RecordingState, transcriptionInFlight: Bool) -> CapturePhase {
        switch state {
        case .recording: .recording
        case .finalizing: .finishing
        case .recorded: transcriptionInFlight ? .finishing : .idle
        case .idle, .requestingPermission, .ready, .failed: .idle
        }
    }

    static func live(_ state: LiveRecordingState) -> CapturePhase {
        switch state {
        case .recording, .recovering: .recording
        case .stopping, .draining: .finishing
        case .idle, .requestingPermission, .failed: .idle
        }
    }

    static func mixed(_ state: MixedAudioRecordingState, isDraining: Bool) -> CapturePhase {
        if isDraining { return .finishing }
        return switch state {
        case .starting, .recording, .recovering: .recording
        case .stopping: .finishing
        case .idle, .failed: .idle
        }
    }
}

/// Menu-bar recording indicator rules.
enum MenuBarRules {
    static let recentLineCount = 3
    static let recentLineMaxCharacters = 60

    static func isShown(_ phase: CapturePhase) -> Bool { phase.isActive }

    /// `H:MM:SS`, also under an hour (the menu bar keeps a stable width).
    static func elapsedText(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d:%02d", seconds / 3_600, (seconds / 60) % 60, seconds % 60)
    }

    /// Menu-bar title next to the red dot.
    static func label(phase: CapturePhase, startedAt: Date?, now: Date) -> String {
        switch phase {
        case .idle: ""
        case .finishing: "轉錄中…"
        case .recording: startedAt.map { elapsedText(from: $0, to: now) } ?? "錄音中"
        }
    }

    static func stopButtonTitle(mode: AudioInputMode) -> String {
        mode == .live ? "停止即時模式" : "停止並轉錄"
    }

    /// Stop is offered only while capturing, only when the main window's own stop is enabled
    /// (ContentView ignores the toggle otherwise), and only once until the phase changes.
    static func stopEnabled(phase: CapturePhase, canStop: Bool, stopRequested: Bool) -> Bool {
        phase == .recording && canStop && !stopRequested
    }

    static func modeTitle(_ mode: AudioInputMode) -> String {
        switch mode {
        case .standard: "標準錄音"
        case .live: "即時轉錄"
        case .mixed: "混音錄音"
        }
    }

    /// Last non-empty transcript lines without their leading `[HH:MM:SS]` / `[MM:SS]` timecode,
    /// each cut to `maxCharacters` with a trailing ….
    static func recentLines(
        _ transcript: String, count: Int = recentLineCount, maxCharacters: Int = recentLineMaxCharacters
    ) -> [String] {
        transcript.split(whereSeparator: \.isNewline)
            .map { stripTimecode(String($0)).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(count)
            .map { $0.count > maxCharacters ? String($0.prefix(maxCharacters)) + "…" : $0 }
    }

    private static func stripTimecode(_ line: String) -> String {
        line.replacingOccurrences(of: #"^\s*\[\d{1,2}(:\d{2}){1,2}\]\s*"#, with: "", options: .regularExpression)
    }
}

/// Main-window protection while a capture is active (the window holds the chunk-accumulation and
/// stop-and-save flow, so it must not be destroyed mid-recording).
enum MainWindowRules {
    enum CloseAction: Equatable {
        case hide
        case close
    }

    static func closeAction(phase: CapturePhase) -> CloseAction { phase.isActive ? .hide : .close }

    static func quitNeedsConfirmation(phase: CapturePhase) -> Bool { phase.isActive }

    static let quitConfirmationMessage = "錄音進行中，結束 Whisper 會中斷錄音。確定要結束嗎？"
}
