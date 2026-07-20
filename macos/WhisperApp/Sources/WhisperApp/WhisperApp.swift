import SwiftUI

@main
@MainActor
struct WhisperDesktopApp: App {
    @State private var worker: WorkerSupervisor
    @State private var recording: StandardRecordingController
    @State private var liveRecording: LiveRecordingController
    @State private var systemAudioPermission: SystemAudioPermissionController
    @State private var systemAudioRecording: SystemAudioRecordingController
    @State private var mixedAudioRecording: MixedAudioRecordingController
    @State private var settings: AppSettingsStore
    @State private var history: TranscriptionHistoryStore
    @State private var updates: UpdateController
    @State private var batch: BatchTranscriptionController
    @State private var summaries: MeetingSummaryStore
    @State private var summaryController: MeetingSummaryController
    @State private var vocabulary: VocabularyStore
    @State private var historyDeletion: HistoryDeletionCoordinator

    init() {
        let worker = WorkerSupervisor()
        let settings = AppSettingsStore()
        let history = TranscriptionHistoryStore(maximumEntries: settings.historyRetention)
        let systemAudioPermission = SystemAudioPermissionController()
        let systemAudioBackend = ScreenCaptureKitAudioBackend()
        let systemAudioLifecycle = SystemAudioCaptureLifecycleController(
            permission: systemAudioPermission,
            backend: systemAudioBackend
        )
        let systemAudioRecording = SystemAudioRecordingController(
            lifecycle: systemAudioLifecycle,
            backend: systemAudioBackend,
            transcriber: worker
        )
        let mixedAudioRecording = MixedAudioRecordingController(
            microphonePermission: SystemMicrophonePermissionProvider(),
            screenPermission: systemAudioPermission,
            microphoneBackend: AVAudioEngineCaptureBackend(),
            systemBackend: ScreenCaptureKitAudioBackend(),
            scheduler: TimerChunkRotationScheduler(),
            transcriber: worker
        )
        worker.transcriptionCompletedHandler = { [weak history, weak systemAudioRecording, weak mixedAudioRecording] completed in
            guard systemAudioRecording?.ownsChunk(completed.audioURL) != true,
                  mixedAudioRecording?.ownsChunk(completed.audioURL) != true else { return }
            _ = try? history?.recordCompleted(
                audioURL: completed.audioURL,
                model: completed.modelName,
                language: completed.language,
                text: completed.text,
                segments: completed.segments,
                durationSeconds: completed.durationSeconds,
                domain: completed.domain,
                extraTerms: completed.extraTerms
            )
        }
        _worker = State(initialValue: worker)
        _settings = State(initialValue: settings)
        _history = State(initialValue: history)
        _updates = State(initialValue: UpdateController.production())
        _batch = State(initialValue: BatchTranscriptionController(worker: worker))
        let summaries = MeetingSummaryStore()
        _summaries = State(initialValue: summaries)
        _summaryController = State(initialValue: MeetingSummaryController(store: summaries))
        _vocabulary = State(initialValue: VocabularyStore())
        _historyDeletion = State(initialValue: HistoryDeletionCoordinator(
            history: history, summaries: summaries, settings: settings
        ))
        _recording = State(initialValue: StandardRecordingController(
            microphone: MicrophoneCaptureService(),
            transcriber: worker
        ))
        _liveRecording = State(initialValue: LiveRecordingController(transcriber: worker))
        _systemAudioPermission = State(initialValue: systemAudioPermission)
        _systemAudioRecording = State(initialValue: systemAudioRecording)
        _mixedAudioRecording = State(initialValue: mixedAudioRecording)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(worker)
                .environment(recording)
                .environment(liveRecording)
                .environment(systemAudioPermission)
                .environment(systemAudioRecording)
                .environment(mixedAudioRecording)
                .environment(settings)
                .environment(history)
                .environment(updates)
                .environment(batch)
                .environment(summaries)
                .environment(summaryController)
                .environment(vocabulary)
                .environment(historyDeletion)
        }
        .commands {
            CommandMenu("Transcription") {
                Button("Import Audio…") { NotificationCenter.default.post(name: .whisperImportAudio, object: nil) }
                    .keyboardShortcut("u", modifiers: .command)
                Button("Start or Stop Recording") {
                    NotificationCenter.default.post(name: .whisperToggleRecording, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("Copy Current Transcript") {
                    NotificationCenter.default.post(name: .whisperCopyResult, object: nil)
                }
                .keyboardShortcut("c", modifiers: [.command, .option])
                Button("Clear Current Workspace") {
                    NotificationCenter.default.post(name: .whisperClearWorkspace, object: nil)
                }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
            }
        }
    }
}
