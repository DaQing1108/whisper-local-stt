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
        case .mixed: canStartMixedAudioRecording
        }
    }

    var primaryButtonLabel: String {
        StatusTextRules.primaryButtonLabel(mode: audioMode, isRecording: isPrimaryRecording)
    }

    var primaryStatusText: String? {
        switch audioMode {
        case .standard: StatusTextRules.standardStatus(recording.state)
        case .live: StatusTextRules.liveStatus(liveRecording.state)
        case .mixed: StatusTextRules.mixedStatus(
            mixedAudioRecording.state,
            isDraining: mixedAudioRecording.isDraining,
            submissionError: mixedAudioRecording.submissionQueue.errorMessage,
            includesMicrophone: settings.includeMicrophoneInMixedMode
        )
        }
    }

    var modeHelpText: String {
        switch audioMode {
        case .standard: "錄完後一次轉錄，適合會議與訪談。"
        case .live: "錄音時分段轉錄，裝置切換時會自動復原。"
        case .mixed: settings.includeMicrophoneInMixedMode
            ? "同時錄製自己的麥克風與 Mac 系統聲音。"
            : "擷取 Mac 播放的聲音，例如 Teams 或 Zoom。"
        }
    }

    func primaryCaptureAction() {
        if isPrimaryRecording {
            switch audioMode {
            case .standard: stopRecording()
            case .live: captureStartedAt = nil; liveRecording.stop()
            case .mixed: stopMixedAudioRecording()
            }
        } else {
            resetWorkspaceForNewCapture()
            switch audioMode {
            case .standard: startRecording()
            case .live: startLiveRecording()
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

    func startMixedAudioRecording() {
        mixedAudioHistoryEntryID = nil
        mixedAudioRecording.applySettings(
            model: settings.defaultModel, language: settings.language,
            domain: settings.domain, extraTerms: effectiveExtraTerms
        )
        Task {
            do {
                let url = try MixedAudioRecordingController.makeSessionOutputURL()
                try await mixedAudioRecording.start(
                    outputURL: url,
                    includeMicrophone: settings.includeMicrophoneInMixedMode
                )
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
                   let sessionURL = mixedAudioRecording.sessionFinalizedURL,
                   let updated = try history.updateResult(
                       id: id,
                       text: mixedAudioRecording.transcriptText,
                       segments: mixedAudioRecording.transcriptSegments,
                       durationSeconds: mixedAudioRecording.transcriptDurationSeconds,
                       audioURL: sessionURL
                   ) {
                    if CaptureUIRules.shouldSyncFinalizedMixedAudioResult(isDraftDirty: isDraftDirty) {
                        restore(updated)
                    }
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
        guard !recording.isStarting, !liveOwnsMicrophone, !mixedAudioOwnsCapture else { return false }
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
              !recording.isStarting, !recording.state.canStop, !mixedAudioOwnsCapture else { return false }
        return switch liveRecording.state {
        case .idle, .failed: true
        case .requestingPermission, .recording, .recovering, .stopping, .draining: false
        }
    }

    var canStartMixedAudioRecording: Bool {
        guard systemAudioPermission.status == .granted,
              worker.state == .ready,
              worker.activeRequestID == nil,
              !recording.isStarting,
              !recording.state.canStop,
              !liveOwnsMicrophone else { return false }
        return mixedAudioRecording.canStart
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
}
