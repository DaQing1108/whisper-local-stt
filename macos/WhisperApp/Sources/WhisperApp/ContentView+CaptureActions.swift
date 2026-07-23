import Foundation
import SwiftUI

extension ContentView {
    var audioMode: AudioInputMode { settings.audioMode }

    var effectiveExtraTerms: String {
        [vocabulary.activeTermsText, settings.extraTerms]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: ", ")
    }

    var modelReadinessSymbol: String {
        switch worker.modelReadiness {
        case "ready": "checkmark.circle.fill"
        case "cached": "internaldrive.fill"
        case "loading": "arrow.down.circle"
        case "needs_download": "icloud.and.arrow.down"
        case "failed": "exclamationmark.triangle.fill"
        default: "questionmark.circle"
        }
    }

    func checkModelStatus() {
        do { try worker.requestModelStatus(modelName: settings.defaultModel); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }

    func warmupSelectedModel() {
        do { try worker.warmupModel(modelName: settings.defaultModel); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }

    var anyCaptureActive: Bool {
        CaptureUIRules.shouldLockMode(
            standardPendingOrActive: recording.isStarting || recording.state.canStop,
            livePendingOrActive: liveOwnsMicrophone,
            systemPendingOrActive: systemAudioOperationInFlight,
            mixedPendingOrActive: mixedAudioOwnsCapture
        )
    }

    var isPrimaryRecording: Bool {
        switch audioMode {
        case .standard: recording.state.canStop
        case .live: CaptureUIRules.liveIsStoppable(
            recording: liveRecording.state == .recording,
            recovering: liveRecording.state == .recovering
        )
        case .system: systemAudioRecording.canStop
        case .mixed: mixedAudioRecording.hasActiveOperation
        }
    }

    var primaryActionEnabled: Bool {
        if isPrimaryRecording {
            return CaptureUIRules.stopIsEnabled(
                mode: audioMode,
                workerHasActiveJob: worker.activeJobID != nil
            )
        }
        return switch audioMode {
        case .standard: canStartRecording
        case .live: canStartLiveRecording
        case .system: canStartSystemAudioRecording
        case .mixed: canStartMixedAudioRecording
        }
    }

    var primaryButtonLabel: String {
        if isPrimaryRecording {
            return audioMode == .live ? "停止即時模式" : "停止並轉錄"
        }
        return switch audioMode {
        case .standard: "開始錄音"
        case .live: "開始即時轉錄"
        case .system: "開始錄製系統音訊"
        case .mixed: "開始錄製麥克風與系統音訊"
        }
    }

    var primaryStatusText: String {
        switch audioMode {
        case .standard: recordingStatusText
        case .live: liveRecordingStatusText
        case .system: systemAudioRecordingStatusText
        case .mixed: mixedAudioRecordingStatusText
        }
    }

    var modeHelpText: String {
        switch audioMode {
        case .standard: "錄完後一次轉錄，適合會議與訪談。"
        case .live: "錄音時分段轉錄，裝置切換時會自動復原。"
        case .system: "擷取 Mac 播放的聲音，例如 Teams 或 Zoom。"
        case .mixed: "同時錄製自己的麥克風與 Mac 系統聲音。"
        }
    }

    func primaryCaptureAction() {
        if isPrimaryRecording {
            switch audioMode {
            case .standard: stopRecording()
            case .live: captureStartedAt = nil; liveRecording.stop()
            case .system: stopSystemAudioRecording()
            case .mixed: stopMixedAudioRecording()
            }
        } else {
            resetWorkspaceForNewCapture()
            switch audioMode {
            case .standard: startRecording()
            case .live: startLiveRecording()
            case .system: startSystemAudioRecording()
            case .mixed: startMixedAudioRecording()
            }
        }
    }

    /// Clears the workspace's stale entry before a new recording starts, so the
    /// previous result's transcript/segments don't linger on screen mid-recording.
    func resetWorkspaceForNewCapture() {
        currentEntryID = nil
        transientEntry = nil
        transcriptDraft = ""
        isDraftDirty = false
        switchSummaryWorkspace()
    }

    func startTranscription() {
        guard let selectedFile else { return }
        do {
            _ = try worker.transcribe(
                audioURL: selectedFile,
                modelName: settings.defaultModel,
                language: settings.language,
                domain: settings.domain,
                extraTerms: effectiveExtraTerms
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startRecording() {
        Task {
            await recording.start()
            if recording.state.canStop { captureStartedAt = Date() }
            errorMessage = recording.errorMessage
        }
    }

    func startLiveRecording() {
        liveRecording.modelName = settings.defaultModel
        liveRecording.language = settings.language
        liveRecording.domain = settings.domain
        liveRecording.extraTerms = effectiveExtraTerms
        Task { await liveRecording.start(); if liveRecording.state == .recording { captureStartedAt = Date() } }
    }

    func stopRecording() {
        captureStartedAt = nil
        do {
            selectedFile = try recording.stopAndTranscribe(
                modelName: settings.defaultModel, language: settings.language,
                domain: settings.domain, extraTerms: effectiveExtraTerms
            )
            errorMessage = nil
        } catch {
            selectedFile = recording.finalizedAudioURL
            errorMessage = recording.errorMessage ?? error.localizedDescription
        }
    }

    func startSystemAudioRecording() {
        systemAudioHistoryEntryID = nil
        Task {
            systemAudioPermission.refresh()
            guard systemAudioPermission.status == .granted ||
                    systemAudioPermission.requestAccess() == .granted else {
                errorMessage = systemAudioPermission.statusMessage
                return
            }
            do {
                try await systemAudioRecording.start(
                    modelName: settings.defaultModel, language: settings.language,
                    domain: settings.domain, extraTerms: effectiveExtraTerms
                )
                captureStartedAt = Date()
                errorMessage = nil
            }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func stopSystemAudioRecording() {
        captureStartedAt = nil
        presentNextCompletedResult = true
        Task {
            do {
                selectedFile = try await systemAudioRecording.stopAndTranscribe(
                    modelName: settings.defaultModel, language: settings.language,
                    domain: settings.domain, extraTerms: effectiveExtraTerms
                )
                if let id = systemAudioHistoryEntryID,
                   let sessionURL = systemAudioRecording.sessionFinalizedURL {
                    _ = try history.updateResult(
                        id: id,
                        text: systemAudioRecording.transcriptText,
                        segments: systemAudioRecording.transcriptSegments,
                        durationSeconds: systemAudioRecording.transcriptDurationSeconds,
                        audioURL: sessionURL
                    )
                }
                errorMessage = nil
            } catch {
                presentNextCompletedResult = false
                selectedFile = systemAudioRecording.lastFinalizedURL
                errorMessage = error.localizedDescription
            }
        }
    }

    func startMixedAudioRecording() {
        mixedAudioHistoryEntryID = nil
        Task {
            do {
                let url = try MixedAudioRecordingController.makeSessionOutputURL()
                try await mixedAudioRecording.start(outputURL: url)
                captureStartedAt = Date()
                errorMessage = nil
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func stopMixedAudioRecording() {
        captureStartedAt = nil
        presentNextCompletedResult = true
        Task {
            do {
                selectedFile = try await mixedAudioRecording.stopAndTranscribe(
                    modelName: settings.defaultModel, language: settings.language,
                    domain: settings.domain, extraTerms: effectiveExtraTerms
                )
                if let id = mixedAudioHistoryEntryID,
                   let sessionURL = mixedAudioRecording.sessionFinalizedURL {
                    _ = try history.updateResult(
                        id: id,
                        text: mixedAudioRecording.transcriptText,
                        segments: mixedAudioRecording.transcriptSegments,
                        durationSeconds: mixedAudioRecording.transcriptDurationSeconds,
                        audioURL: sessionURL
                    )
                }
                errorMessage = nil
            } catch {
                presentNextCompletedResult = false
                selectedFile = mixedAudioRecording.lastFinalizedURL
                errorMessage = error.localizedDescription
            }
        }
    }

    var canStartRecording: Bool {
        guard !recording.isStarting, !liveOwnsMicrophone, !systemAudioOwnsCapture, !mixedAudioOwnsCapture else { return false }
        return switch recording.state {
        case .idle, .recorded, .failed: true
        case .requestingPermission, .ready, .recording, .finalizing: false
        }
    }

    static func elapsedString(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        return String(format: "%02d:%02d:%02d", seconds / 3_600, (seconds / 60) % 60, seconds % 60)
    }

    var canStartLiveRecording: Bool {
        guard worker.state == .ready, worker.activeRequestID == nil,
              !recording.isStarting, !recording.state.canStop, !systemAudioOwnsCapture, !mixedAudioOwnsCapture else { return false }
        return switch liveRecording.state {
        case .idle, .failed: true
        case .requestingPermission, .recording, .recovering, .stopping, .draining: false
        }
    }

    var canStartSystemAudioRecording: Bool {
        CaptureUIRules.systemAudioStartIsEnabled(
            workerReady: worker.state == .ready,
            workerHasActiveRequest: worker.activeRequestID != nil,
            conflictingCaptureActive: recording.isStarting || recording.state.canStop ||
                liveOwnsMicrophone || mixedAudioOwnsCapture,
            controllerCanStart: systemAudioRecording.canStart
        )
    }

    var canStartMixedAudioRecording: Bool {
        guard systemAudioPermission.status == .granted,
              worker.state == .ready,
              worker.activeRequestID == nil,
              !recording.isStarting,
              !recording.state.canStop,
              !liveOwnsMicrophone,
              !systemAudioOwnsCapture else { return false }
        return mixedAudioRecording.canStart
    }

    var systemAudioOwnsCapture: Bool {
        systemAudioRecording.hasActiveOperation
    }

    var systemAudioOperationInFlight: Bool {
        systemAudioRecording.hasActiveOperation || systemAudioRecording.state == .starting ||
            systemAudioRecording.state == .stopping
    }

    var mixedAudioOwnsCapture: Bool { mixedAudioRecording.hasActiveOperation }

    var liveOwnsMicrophone: Bool {
        switch liveRecording.state {
        case .requestingPermission, .recording, .recovering, .stopping: true
        case .idle, .draining, .failed: false
        }
    }

    var liveOwnsWorker: Bool {
        switch liveRecording.state {
        case .recording, .recovering, .stopping, .draining: true
        case .idle, .requestingPermission, .failed: false
        }
    }

    var liveRecordingStatusText: String {
        switch liveRecording.state {
        case .idle: "Live mode idle"
        case .requestingPermission: "Requesting microphone permission…"
        case .recording: "Live recording — \(liveRecording.finalizedChunkURLs.count) chunks finalized"
        case .recovering: "Recovering microphone capture…"
        case .stopping: "Stopping live recording…"
        case .draining: "Transcribing remaining live chunks…"
        case .failed(let message): "Live mode error: \(message)"
        }
    }

    var recordingStatusText: String {
        switch recording.state {
        case .idle: "Microphone idle"
        case .requestingPermission: "Requesting microphone permission…"
        case .ready: "Microphone ready"
        case .recording: "Recording…"
        case .finalizing: "Finalizing recording…"
        case .recorded(let url): "Saved: \(url.lastPathComponent)"
        case .failed(let message): "Microphone error: \(message)"
        }
    }

    var systemAudioRecordingStatusText: String {
        if let queueError = systemAudioRecording.submissionQueue.errorMessage {
            return "System audio transcription paused: \(queueError). Restart Worker to retry."
        }
        if systemAudioRecording.isDraining {
            return "Transcribing remaining system audio chunks…"
        }
        return switch systemAudioRecording.state {
        case .idle: "System audio idle"
        case .starting: "Starting system audio…"
        case .capturing: "Recording system audio — \(systemAudioRecording.finalizedChunkURLs.count) chunks finalized"
        case .stopping: "Stopping system audio…"
        case .failed(let message): "System audio error: \(message)"
        }
    }

    var mixedAudioRecordingStatusText: String {
        if let queueError = mixedAudioRecording.submissionQueue.errorMessage {
            return "Mixed audio transcription paused: \(queueError). Restart Worker to retry."
        }
        if mixedAudioRecording.isDraining {
            return "Transcribing remaining mixed audio chunks…"
        }
        return switch mixedAudioRecording.state {
        case .idle: "Mixed audio idle"
        case .starting: "Starting mic + system audio…"
        case .recording: "Recording mic + system audio — \(mixedAudioRecording.finalizedChunkURLs.count) chunks finalized"
        case .stopping: "Stopping mixed audio…"
        case .failed(let message): "Mixed audio error: \(message)"
        }
    }
}
