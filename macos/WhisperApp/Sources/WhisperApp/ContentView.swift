import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import AppKit

@MainActor
struct ContentView: View {
    @Environment(\.scenePhase) var scenePhase
    @Environment(WorkerSupervisor.self) var worker
    @Environment(StandardRecordingController.self) var recording
    @Environment(LiveRecordingController.self) var liveRecording
    @Environment(SystemAudioPermissionController.self) var systemAudioPermission
    @Environment(MixedAudioRecordingController.self) var mixedAudioRecording
    @Environment(AppSettingsStore.self) var settings
    @Environment(TranscriptionHistoryStore.self) var history
    @Environment(UpdateController.self) var updates
    @Environment(BatchTranscriptionController.self) var batch
    @Environment(MeetingSummaryStore.self) var summaries
    @Environment(MeetingSummaryController.self) var summaryController
    @Environment(VocabularyStore.self) var vocabulary
    @Environment(HistoryDeletionCoordinator.self) var historyDeletion
    @State var isChoosingFile = false
    @State var isChoosingBatchFiles = false
    @State var isChoosingObsidianVault = false
    @State var selectedFile: URL?
    @State var errorMessage: String?
    @State var obsidianStatus: String?
    @State var notionToken = ""
    @State var notionStatus: String?
    @State var notionUploadInProgress = false
    @State var currentEntryID: UUID?
    @State var mixedAudioHistoryEntryID: UUID?
    @State var liveHistoryEntryID: UUID?
    @State var transientEntry: TranscriptionHistoryEntry?
    @State var transcriptDraft = ""
    @State var isDraftDirty = false
    @State var diarizationTargetEntryID: UUID?
    @State var audioPlayer: AVAudioPlayer?
    @State var playingSegmentIndex: Int?
    @State var playbackPollTimer: Timer?
    @State var exportDocument: TranscriptionExportDocument?
    @State var exportFilename = "transcript.txt"
    @State var isExporting = false
    @State var meetingTitle = ""
    @State var summaryDraft = ""
    @State var isSummaryDirty = false
    @State var summaryDraftOwnerID: UUID?
    @State var pendingSummaryDrafts: [UUID: PendingSummaryDraft] = [:]
    @State var openAIAPIKey = ""
    @State var anthropicAPIKey = ""
    @State var newVocabularyTerm = ""
    @State var historyQuery = ""
    @State var captureStartedAt: Date?
    @State var presentNextCompletedResult = false
    @State var selectedSection: SidebarSection? = .capture
    @State var languageDraft = ""
    @State var isSettingsPopoverPresented = false
    @State var selectedWorkspaceTab: WorkspaceTab = .transcript

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $selectedSection) { section in
                Label(section.title, systemImage: section.symbol).tag(section)
            }
            .tint(DaylightPalette.accentActive)
            .navigationTitle(AppIdentity.displayName)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            VStack(spacing: 0) {
                Group {
                    if selectedSection ?? .capture == .capture { compactControlBar } else { header }
                }
                .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 12)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: DaylightMetric.sectionSpacing) {
                        switch selectedSection ?? .capture {
                        case .capture:
                            workspaceContainer
                        case .history:
                            historySection
                        case .vocabulary:
                            vocabularySection
                        case .integrations, .settings:
                            advancedSettings
                        }
                        messages
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
                }
                .background(DaylightPalette.surface)
            }
        }
        .frame(minWidth: 820, minHeight: 620)
        .task {
            if worker.state == .stopped { startWorker() }
            systemAudioPermission.refresh()
            if let latest = history.entries.first { restore(latest) }
        }
        .onChange(of: history.entries.first?.id) { _, _ in
            if !isDraftDirty, let latest = history.entries.first { restore(latest) }
        }
        .onChange(of: worker.completionRevision) { _, _ in
            showLatestWorkerResultIfNeeded()
        }
        .onChange(of: worker.unsuccessfulTerminalRevision) { _, _ in
            presentNextCompletedResult = false
        }
        .onChange(of: currentEntryID) { _, _ in switchSummaryWorkspace() }
        .onChange(of: currentSummary?.updatedAt) { _, _ in
            if !isSummaryDirty { loadSummaryWorkspace() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { systemAudioPermission.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .whisperImportAudio)) { _ in
            isChoosingFile = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .whisperToggleRecording)) { _ in
            if primaryActionEnabled { primaryCaptureAction() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .whisperCopyResult)) { _ in
            if !transcriptDraft.isEmpty { copyDraft() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .whisperClearWorkspace)) { _ in
            transcriptDraft = ""
            isDraftDirty = true
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .plainText,
            defaultFilename: exportFilename
        ) { result in
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
        }
        .fileImporter(
            isPresented: $isChoosingFile,
            allowedContentTypes: [.audio, .movie],
            allowsMultipleSelection: false
        ) { result in
            do { selectedFile = try result.get().first }
            catch { errorMessage = error.localizedDescription }
        }
        .fileImporter(
            isPresented: $isChoosingBatchFiles,
            allowedContentTypes: [.audio, .movie],
            allowsMultipleSelection: true
        ) { result in
            do {
                try batch.replaceFiles(result.get())
                errorMessage = nil
            } catch { errorMessage = error.localizedDescription }
        }
        .fileImporter(
            isPresented: $isChoosingObsidianVault,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            do {
                guard let selected = try result.get().first else { return }
                let validated = try ObsidianExportService().validateVault(selected)
                settings.obsidianVaultPath = validated.path
                obsidianStatus = "Obsidian Vault selected: \(validated.lastPathComponent)"
            } catch {
                obsidianStatus = "Obsidian Vault error: \(error.localizedDescription)"
            }
        }
    }

    var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 38, height: 38)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(AppIdentity.displayName).font(.title2.weight(.semibold))
                Text("本地語音 AI").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            StatusBadge(text: statusText, color: statusColor)
        }
    }

    @ViewBuilder var messages: some View {
        if let historyError = history.loadError ?? history.writeError {
            Label("歷史紀錄錯誤：\(historyError)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
        if let summaryError = summaries.loadError ?? summaries.writeError ?? summaryController.lastError {
            Label("摘要錯誤：\(summaryError)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
        if let deletionError = historyDeletion.errorMessage {
            Label("刪除同步待重試：\(deletionError)", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.red)
        }
        if let obsidianStatus { Text(obsidianStatus).foregroundStyle(.secondary) }
        if let notionStatus { Text(notionStatus).foregroundStyle(.secondary) }
        if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
        if let recordingError = recording.errorMessage { Text(recordingError).foregroundStyle(.red) }
    }

    var statusText: String {
        switch worker.state {
        case .stopped: "Worker stopped"
        case .starting: "Starting Python Worker…"
        case .restarting(let attempt): "Restarting Python Worker (attempt \(attempt))…"
        case .ready: "Python Worker ready"
        case .failed(let message): "Worker error: \(message)"
        }
    }

    var statusColor: Color {
        if worker.state == .ready { return DaylightPalette.accentActive }
        if case .failed = worker.state { return DaylightPalette.accentRecord }
        return .secondary
    }
}
