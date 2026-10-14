import Foundation

/// User-facing status wording. `nil` means "nothing to show" — a ready Worker and an idle
/// recorder need no badge or status line (status only appears when it needs attention).
enum StatusTextRules {
    static func workerStatus(_ state: WorkerState) -> String? {
        switch state {
        case .ready: nil
        case .stopped: "轉錄引擎已停止"
        case .starting: "轉錄引擎啟動中…"
        case .restarting(let attempt): "轉錄引擎重新啟動中（第 \(attempt) 次）…"
        case .failed(let message): "轉錄引擎錯誤：\(message)"
        }
    }

    static func standardStatus(_ state: RecordingState) -> String? {
        switch state {
        case .idle, .ready, .recorded: nil
        case .requestingPermission: "正在要求麥克風權限…"
        case .recording: "錄音中…"
        case .finalizing: "正在儲存錄音…"
        case .failed(let message): "錄音錯誤：\(message)"
        }
    }

    static func liveStatus(_ state: LiveRecordingState) -> String? {
        switch state {
        case .idle: nil
        case .requestingPermission: "正在要求麥克風權限…"
        case .recording: "即時轉錄中…"
        case .recovering: "音訊裝置恢復中…"
        case .stopping: "停止中…"
        case .draining: "正在轉錄最後幾段…"
        case .failed(let message): "錄音錯誤：\(message)"
        }
    }

    static func mixedStatus(
        _ state: MixedAudioRecordingState,
        isDraining: Bool,
        submissionError: String?,
        includesMicrophone: Bool
    ) -> String? {
        if let submissionError { return "轉錄暫停：\(submissionError)（請重新啟動轉錄引擎）" }
        if isDraining { return "正在轉錄最後幾段…" }
        return switch state {
        case .idle: nil
        case .starting: "啟動中…"
        case .recording: includesMicrophone ? "錄音中（麥克風＋系統音訊）" : "錄音中（系統音訊）"
        case .recovering: "音訊裝置恢復中…"
        case .stopping: "停止中…"
        case .failed(let message): "錄音錯誤：\(message)"
        }
    }

    /// Short verb so the button never truncates; the mode is shown by the mode picker and tooltip.
    static func primaryButtonLabel(mode: AudioInputMode, isRecording: Bool) -> String {
        if isRecording { return mode == .live ? "停止即時模式" : "停止並轉錄" }
        return mode == .live ? "開始即時轉錄" : "開始錄音"
    }

    /// Worker job status in Chinese. Worker-provided progress messages are already Chinese
    /// and pass through unchanged.
    static func jobStatus(_ status: String) -> String {
        switch status {
        case "Submitting": "送出中…"
        case "Queued": "排隊中…"
        case "Running", "Transcribing": "轉錄中…"
        case "Completed": "已完成"
        case "Cancelled": "已取消"
        case "Failed": "轉錄失敗"
        case "Idle": ""
        default: status
        }
    }

    static func modelReadiness(_ readiness: String) -> String {
        switch readiness {
        case "ready": "模型已就緒"
        case "cached": "模型已下載，可預先載入"
        case "needs_download": "第一次使用需要下載模型"
        case "loading": "模型載入中…"
        case "failed": "模型檢查失敗"
        default: "尚未檢查模型"
        }
    }

    static func domainName(_ domain: String) -> String {
        switch domain {
        case "general": "通用"
        case "media": "媒體"
        case "tech": "科技"
        case "medical": "醫療"
        case "legal": "法律"
        default: domain
        }
    }

    static func batchStatus(_ status: BatchItemStatus) -> String {
        switch status {
        case .pending: "等待中"
        case .running: "轉錄中"
        case .completed: "已完成"
        case .failed: "失敗"
        case .cancelled: "已取消"
        }
    }
}

/// What the transcript area shows. Reading mode (default) is the clickable timecode list;
/// editing mode is the text editor — never both at once.
enum TranscriptViewRules {
    enum Body: Equatable {
        case segmentList
        case readOnlyText
        case editor
    }

    /// `draftDiverged`: the draft no longer matches the saved segments (unsaved edits, or an
    /// edit saved since those segments were transcribed — e.g. speaker labels or a rename).
    /// The timecode list would show stale text then, so reading mode shows the draft instead.
    static func body(isEditing: Bool, hasSegments: Bool, draftDiverged: Bool = false) -> Body {
        if isEditing { return .editor }
        return hasSegments && !draftDiverged ? .segmentList : .readOnlyText
    }

    /// True while there are unsaved edits, or an edit was saved and the segments have not been
    /// re-transcribed since (`segmentsWhenEdited` equals the entry's current segments).
    static func draftDiverged(
        isDraftDirty: Bool,
        segmentsWhenEdited: [TranscriptionSegment]?,
        currentSegments: [TranscriptionSegment]
    ) -> Bool {
        isDraftDirty || segmentsWhenEdited == currentSegments
    }

    static func showsEditedNotice(isEditing: Bool, isDraftDirty: Bool, draftDiverged: Bool) -> Bool {
        !isEditing && !isDraftDirty && draftDiverged
    }

    /// Reading mode shows saved segments; flag that the draft has edits not reflected there.
    static func showsUnsavedNotice(isEditing: Bool, isDraftDirty: Bool) -> Bool {
        !isEditing && isDraftDirty
    }

    static func showsClearButton(isEditing: Bool) -> Bool { isEditing }

    static func editToggleLabel(isEditing: Bool) -> String { isEditing ? "完成" : "編輯" }

    /// Job status, progress bar and cancel only while a transcription request is in flight —
    /// but not per-chunk during live/mixed capture, where they would flicker on every chunk.
    static func showsJobControls(hasActiveRequest: Bool, isChunkedCaptureActive: Bool = false) -> Bool {
        hasActiveRequest && !isChunkedCaptureActive
    }

    /// Follow new segments only when the user is already looking at the end of the list.
    static func shouldAutoScroll(isAtBottom: Bool, segmentCountIncreased: Bool) -> Bool {
        isAtBottom && segmentCountIncreased
    }
}
