import Foundation

enum AppIdentity {
    static let displayName = "Whisper Swift"

    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let shortVersion = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let buildNumber = info?["CFBundleVersion"] as? String ?? "0"
        return "\(shortVersion) (\(buildNumber))"
    }
}

enum AudioInputMode: String, CaseIterable, Identifiable {
    case standard
    case live
    case mixed

    var id: Self { self }
    var title: String {
        switch self {
        case .standard: "標準"
        case .live: "即時"
        case .mixed: "混音"
        }
    }
    var symbol: String {
        switch self {
        case .standard: "mic.fill"
        case .live: "waveform.badge.mic"
        case .mixed: "person.2.wave.2.fill"
        }
    }
}

enum CaptureUIRules {
    static func shouldLockMode(
        standardPendingOrActive: Bool,
        livePendingOrActive: Bool,
        mixedPendingOrActive: Bool
    ) -> Bool {
        standardPendingOrActive || livePendingOrActive || mixedPendingOrActive
    }

    static func liveIsStoppable(recording: Bool, recovering: Bool) -> Bool {
        recording || recovering
    }

    static func stopIsEnabled(mode: AudioInputMode, workerHasActiveJob: Bool) -> Bool {
        mode == .live || mode == .mixed || !workerHasActiveJob
    }

    static func shouldPresentCompletedResult(
        isDraftDirty: Bool,
        explicitlyRequestedPresentation: Bool
    ) -> Bool {
        explicitlyRequestedPresentation || !isDraftDirty
    }

    /// Whether a just-finalized mixed-audio result should be reflected in the
    /// visible workspace. Mirrors the existing "don't clobber an in-progress
    /// manual edit" guard used elsewhere (diarization apply, retranscribe apply).
    static func shouldSyncFinalizedMixedAudioResult(isDraftDirty: Bool) -> Bool {
        !isDraftDirty
    }

    /// Warning shown while recording (or about to) if the Worker is busy with speaker
    /// diarization or a model operation: `WorkerSupervisor.transcribe` rejects new jobs
    /// until it finishes, so transcription is deferred (the audio file is still saved).
    static func transcriptionDeferralNotice(
        mode: AudioInputMode,
        isRecordingOrStarting: Bool,
        diarizationInProgress: Bool,
        modelOperationInProgress: Bool
    ) -> String? {
        guard isRecordingOrStarting, diarizationInProgress || modelOperationInProgress else { return nil }
        let subject = mode == .standard ? "停止後的轉錄" : "這次錄音的轉錄"
        let cause = diarizationInProgress ? "講者辨識進行中" : "模型下載或檢查進行中"
        let waitsFor = diarizationInProgress ? "辨識結束後" : "它結束後"
        return "\(cause)，\(subject)會等\(waitsFor)才開始（錄音檔會正常儲存）"
    }
}

struct PendingSummaryDraft {
    var title: String
    var text: String
}

enum SidebarSection: String, CaseIterable, Identifiable {
    case capture
    case history
    case vocabulary
    case integrations
    case settings

    var id: Self { self }
    var title: String {
        switch self {
        case .capture: "錄製"
        case .history: "歷史紀錄"
        case .vocabulary: "詞庫"
        case .integrations: "Obsidian‧Notion"
        case .settings: "偏好設定"
        }
    }
    var symbol: String {
        switch self {
        case .capture: "mic.fill"
        case .history: "clock.arrow.circlepath"
        case .vocabulary: "text.book.closed"
        case .integrations: "link"
        case .settings: "gearshape"
        }
    }
}
