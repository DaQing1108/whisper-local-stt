import SwiftUI
import AVFoundation

enum WorkspaceTab: Hashable, Identifiable, CaseIterable {
    case transcript
    case summary

    var id: Self { self }

    var title: String {
        switch self {
        case .transcript: "Transcript"
        case .summary: "AI Summary"
        }
    }
}

extension ContentView {
    var workspaceContainer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("工作區").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                PillSegmentedControl(
                    options: WorkspaceTab.allCases,
                    selection: $selectedWorkspaceTab,
                    accessibilityLabel: "工作區分頁"
                ) { tab in Text(tab.title) }
            }
            switch selectedWorkspaceTab {
            case .transcript: transcriptContent
            case .summary: summaryContent
            }
        }
        .cardStyle()
        .overlay(alignment: .bottomTrailing) {
            if selectedWorkspaceTab == .transcript, !transcriptDraft.isEmpty {
                HStack(spacing: 8) {
                    Button { copyDraft() } label: { Image(systemName: "doc.on.doc") }
                    if let entry = currentEntry {
                        Menu { ForEach(TranscriptionExportFormat.allCases) { format in
                            Button(format.rawValue) { export(entry, as: format) }
                                .disabled(format == .srt && entry.segments.isEmpty)
                        } } label: { Image(systemName: "square.and.arrow.up") }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(DaylightPalette.accentActive)
                .padding(14)
            }
        }
        .onChange(of: worker.diarizedSegments) { _, segments in
            guard !segments.isEmpty else { return }
            guard diarizationTargetEntryID != nil, diarizationTargetEntryID == currentEntry?.id else { return }
            guard !isDraftDirty else {
                errorMessage = "講者辨識已完成，但逐字稿已被手動編輯，未覆蓋；請用「複製」另外取用結果。"
                return
            }
            transcriptDraft = Self.renderSpeakerLabeled(segments)
            isDraftDirty = true
            diarizationTargetEntryID = nil
        }
        .onDisappear { stopPlaybackPolling() }
    }

    private var transcriptContent: some View {
        VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(worker.jobStatus).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("取消", role: .destructive) { try? worker.cancel() }
                        .disabled(worker.activeJobID == nil)
                }
                Text(worker.llmPunctuationEnabled ? "✨ 語意校對：已啟用" : "🔇 語意校對：未設定 API Key，已跳過")
                    .font(.caption2).foregroundStyle(.secondary)
                ProgressView(value: worker.progress)
                TextEditor(text: Binding(
                    get: { transcriptDraft },
                    set: { transcriptDraft = $0; isDraftDirty = true }
                ))
                    .lineSpacing(8)
                    .overlay(alignment: .topLeading) {
                        if transcriptDraft.isEmpty {
                            Text("完成錄音或選擇音訊檔後，逐字稿會顯示在這裡。")
                                .foregroundStyle(.tertiary).padding(8).allowsHitTesting(false)
                        }
                    }
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                .frame(minHeight: 180, maxHeight: 300)
                if let entry = currentEntry, !entry.segments.isEmpty {
                    segmentListView(entry)
                }
                HStack {
                    Button("儲存修改") { saveDraft() }.disabled(currentEntryID == nil)
                    Button("複製") { copyDraft() }.disabled(transcriptDraft.isEmpty)
                    Button("清空") { transcriptDraft = ""; isDraftDirty = true }.disabled(transcriptDraft.isEmpty)
                    if let entry = currentEntry {
                        Button(audioPlayer?.isPlaying == true ? "暫停音訊" : "播放音訊") { togglePlayback(entry) }
                        if !worker.diarizationAvailable && worker.diarizationStatus != "ready" {
                            Button(worker.diarizationStatus == "loading" ? "下載模型中…" : "下載講者辨識模型") {
                                triggerDiarizationWarmup()
                            }
                            .disabled(worker.diarizationOperationInProgress || worker.activeRequestID != nil)
                        }
                        Button("辨識講者") { triggerDiarization(entry) }
                            .disabled(entry.segments.isEmpty || worker.diarizationOperationInProgress || worker.activeRequestID != nil)
                        Menu("Export") {
                            ForEach(TranscriptionExportFormat.allCases) { format in
                                Button(format.rawValue) { export(entry, as: format) }
                                    .disabled(format == .srt && entry.segments.isEmpty)
                            }
                        }
                    }
                }
                if let diarizationFailureMessage = worker.diarizationFailureMessage, worker.diarizationStatus == "failed" {
                    Text(diarizationFailureMessage).font(.caption).foregroundStyle(.red)
                }
                if !worker.diagnostics.isEmpty {
                    DisclosureGroup("Worker diagnostics") {
                        Text(worker.diagnostics).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
        }
        .tint(DaylightPalette.accentActive)
    }

    private static let playbackPollInterval: TimeInterval = 0.3
    private static let activeSegmentHighlightOpacity: Double = 0.18

    private func segmentListView(_ entry: TranscriptionHistoryEntry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(entry.segments.enumerated()), id: \.offset) { index, segment in
                    Button {
                        seek(to: segment, index: index, in: entry)
                    } label: {
                        Text(Self.segmentLabel(segment))
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(
                                index == playingSegmentIndex
                                    ? DaylightPalette.accentActive.opacity(Self.activeSegmentHighlightOpacity) : .clear,
                                in: RoundedRectangle(cornerRadius: 4)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(minHeight: 60, maxHeight: 120)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
    }

    static func segmentLabel(_ segment: TranscriptionSegment) -> String {
        let wholeSeconds = max(0, Int(segment.start.rounded(.down)))
        let timestamp = String(format: "%02d:%02d", wholeSeconds / 60, wholeSeconds % 60)
        let speakerPrefix = segment.speaker.map { "[\($0)] " } ?? ""
        return "[\(timestamp)] \(speakerPrefix)\(segment.text)"
    }

    static func renderSpeakerLabeled(_ segments: [TranscriptionSegment]) -> String {
        segments.map { segment in
            if let speaker = segment.speaker { "[\(speaker)] \(segment.text)" } else { segment.text }
        }.joined(separator: "\n")
    }

    func triggerDiarization(_ entry: TranscriptionHistoryEntry) {
        do {
            diarizationTargetEntryID = entry.id
            try worker.diarize(audioPath: entry.audioPath, segments: entry.segments)
            errorMessage = nil
        } catch {
            diarizationTargetEntryID = nil
            errorMessage = "無法啟動講者辨識：\(error.localizedDescription)"
        }
    }

    func triggerDiarizationWarmup() {
        do {
            try worker.diarizationWarmup()
            errorMessage = nil
        } catch {
            errorMessage = "無法啟動模型下載：\(error.localizedDescription)"
        }
    }

    private var summaryContent: some View {
        VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("會議標題", text: Binding(
                        get: { meetingTitle },
                        set: { meetingTitle = $0; isSummaryDirty = true }
                    ))
                    Picker("Provider", selection: Binding(
                        get: { settings.summaryProvider },
                        set: { settings.summaryProvider = $0 }
                    )) {
                        ForEach(MeetingSummaryProvider.allCases, id: \.self) {
                            Text($0.displayName).tag($0)
                        }
                    }
                    .frame(width: 190)
                    .disabled(summaryController.activeTranscriptionID != nil)
                    Spacer()
                    if let summary = currentSummary {
                        StatusBadge(
                            text: "\(summary.provider) · \(summary.status.rawValue)",
                            color: summary.status.daylightColor
                        )
                    }
                }
                TextEditor(text: Binding(
                    get: { summaryDraft },
                    set: { summaryDraft = $0; isSummaryDirty = true }
                ))
                .lineSpacing(8)
                .frame(minHeight: 150, maxHeight: 260)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                HStack {
                    Button("產生摘要") { generateSummary() }
                        .buttonStyle(.borderedProminent)
                        .tint(DaylightPalette.accentActive)
                        .disabled(currentEntryID == nil || summaryController.activeTranscriptionID != nil)
                    Button("儲存摘要修改") { saveSummaryEdit() }
                        .disabled(currentEntryID == nil || currentSummary == nil || !isSummaryDirty)
                    if let error = currentSummary?.errorMessage {
                        Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                    }
                }
        }
    }

    var transcriptText: String {
        worker.resultText.isEmpty ? worker.partialText : worker.resultText
    }

    var currentEntry: TranscriptionHistoryEntry? {
        if let currentEntryID { return history.entries.first { $0.id == currentEntryID } }
        return transientEntry
    }

    var currentSummary: MeetingSummary? {
        guard let currentEntryID else { return nil }
        return summaries.summary(for: currentEntryID)
    }

    func loadSummaryWorkspace(force: Bool = false) {
        guard force || !isSummaryDirty else { return }
        guard let currentEntryID else {
            summaryDraftOwnerID = nil
            meetingTitle = ""
            summaryDraft = ""
            isSummaryDirty = false
            return
        }
        summaryDraftOwnerID = currentEntryID
        if let pending = pendingSummaryDrafts[currentEntryID] {
            meetingTitle = pending.title
            summaryDraft = pending.text
            isSummaryDirty = true
            return
        }
        let summary = currentSummary
        meetingTitle = summary?.meetingTitle ?? currentEntry.map {
            URL(fileURLWithPath: $0.audioPath).deletingPathExtension().lastPathComponent
        } ?? ""
        summaryDraft = summary?.effectiveText ?? ""
        isSummaryDirty = false
    }

    func switchSummaryWorkspace() {
        if isSummaryDirty, let owner = summaryDraftOwnerID {
            pendingSummaryDrafts[owner] = PendingSummaryDraft(title: meetingTitle, text: summaryDraft)
        }
        isSummaryDirty = false
        loadSummaryWorkspace(force: true)
    }

    func generateSummary() {
        guard let entry = currentEntry else { return }
        let title = meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = settings.summaryProvider
        Task {
            let requestedID = entry.id
            await summaryController.generate(
                for: entry,
                title: title.isEmpty ? "未命名會議" : title,
                provider: provider
            )
            if currentEntryID == requestedID { loadSummaryWorkspace() }
        }
    }

    func saveSummaryEdit() {
        guard let owner = summaryDraftOwnerID, owner == currentEntryID else {
            errorMessage = "摘要草稿與目前會議不一致，請重新載入"
            return
        }
        do {
            let title = meetingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            try summaries.saveEdit(
                transcriptionID: owner,
                title: title.isEmpty ? "未命名會議" : title,
                text: summaryDraft
            )
            isSummaryDirty = false
            pendingSummaryDrafts[owner] = nil
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func restore(_ entry: TranscriptionHistoryEntry) {
        currentEntryID = entry.id
        transientEntry = nil
        transcriptDraft = entry.text
        isDraftDirty = false
        audioPlayer?.stop()
        audioPlayer = nil
        stopPlaybackPolling()
        playingSegmentIndex = nil
    }

    func saveDraft() {
        guard let currentEntryID else { return }
        do {
            try history.updateText(id: currentEntryID, text: transcriptDraft)
            isDraftDirty = false
            errorMessage = nil
        }
        catch { errorMessage = error.localizedDescription }
    }

    func showLatestWorkerResultIfNeeded() {
        guard let completed = worker.latestCompletedTranscription else { return }
        if systemAudioRecording.acceptCompletedChunk(
            completed.audioURL,
            text: completed.text,
            segments: completed.segments,
            durationSeconds: completed.durationSeconds
        ) {
            presentNextCompletedResult = false
            do {
                let entry: TranscriptionHistoryEntry
                if let id = systemAudioHistoryEntryID,
                   let updated = try history.updateResult(
                       id: id,
                       text: systemAudioRecording.transcriptText,
                       segments: systemAudioRecording.transcriptSegments,
                       durationSeconds: systemAudioRecording.transcriptDurationSeconds,
                       audioURL: systemAudioRecording.sessionFinalizedURL
                   ) {
                    entry = updated
                } else {
                    entry = try history.recordCompleted(
                        audioURL: systemAudioRecording.sessionFinalizedURL ?? completed.audioURL,
                        model: completed.modelName,
                        language: completed.language,
                        text: systemAudioRecording.transcriptText,
                        segments: systemAudioRecording.transcriptSegments,
                        durationSeconds: systemAudioRecording.transcriptDurationSeconds,
                        domain: completed.domain,
                        extraTerms: completed.extraTerms
                    )
                }
                systemAudioHistoryEntryID = entry.id
                restore(entry)
                errorMessage = nil
            } catch {
                stopPlaybackPolling()
                playingSegmentIndex = nil
                currentEntryID = nil
                transientEntry = TranscriptionHistoryEntry(
                    audioPath: completed.audioURL.path,
                    model: completed.modelName,
                    language: completed.language,
                    text: systemAudioRecording.transcriptText,
                    segments: systemAudioRecording.transcriptSegments,
                    durationSeconds: systemAudioRecording.transcriptDurationSeconds,
                    domain: completed.domain,
                    extraTerms: completed.extraTerms
                )
                transcriptDraft = systemAudioRecording.transcriptText
                isDraftDirty = false
                errorMessage = "History update failed: \(error.localizedDescription)"
            }
            return
        }
        if mixedAudioRecording.acceptCompletedChunk(
            completed.audioURL,
            text: completed.text,
            segments: completed.segments,
            durationSeconds: completed.durationSeconds
        ) {
            presentNextCompletedResult = false
            do {
                let entry: TranscriptionHistoryEntry
                if let id = mixedAudioHistoryEntryID,
                   let updated = try history.updateResult(
                       id: id,
                       text: mixedAudioRecording.transcriptText,
                       segments: mixedAudioRecording.transcriptSegments,
                       durationSeconds: mixedAudioRecording.transcriptDurationSeconds,
                       audioURL: mixedAudioRecording.sessionFinalizedURL
                   ) {
                    entry = updated
                } else {
                    entry = try history.recordCompleted(
                        audioURL: mixedAudioRecording.sessionFinalizedURL ?? completed.audioURL,
                        model: completed.modelName,
                        language: completed.language,
                        text: mixedAudioRecording.transcriptText,
                        segments: mixedAudioRecording.transcriptSegments,
                        durationSeconds: mixedAudioRecording.transcriptDurationSeconds,
                        domain: completed.domain,
                        extraTerms: completed.extraTerms
                    )
                }
                mixedAudioHistoryEntryID = entry.id
                restore(entry)
                errorMessage = nil
            } catch {
                stopPlaybackPolling()
                playingSegmentIndex = nil
                currentEntryID = nil
                transientEntry = TranscriptionHistoryEntry(
                    audioPath: completed.audioURL.path,
                    model: completed.modelName,
                    language: completed.language,
                    text: mixedAudioRecording.transcriptText,
                    segments: mixedAudioRecording.transcriptSegments,
                    durationSeconds: mixedAudioRecording.transcriptDurationSeconds,
                    domain: completed.domain,
                    extraTerms: completed.extraTerms
                )
                transcriptDraft = mixedAudioRecording.transcriptText
                isDraftDirty = false
                errorMessage = "History update failed: \(error.localizedDescription)"
            }
            return
        }
        guard CaptureUIRules.shouldPresentCompletedResult(
            isDraftDirty: isDraftDirty,
            explicitlyRequestedPresentation: presentNextCompletedResult
        ) else { return }
        presentNextCompletedResult = false
        if let persisted = history.entries.first,
           persisted.audioPath == completed.audioURL.path,
           persisted.text == completed.text {
            restore(persisted)
            return
        }
        stopPlaybackPolling()
        playingSegmentIndex = nil
        currentEntryID = nil
        transientEntry = TranscriptionHistoryEntry(
            audioPath: completed.audioURL.path,
            model: completed.modelName,
            language: completed.language,
            text: completed.text,
            segments: completed.segments,
            durationSeconds: completed.durationSeconds,
            domain: completed.domain,
            extraTerms: completed.extraTerms
        )
        transcriptDraft = completed.text
        isDraftDirty = false
    }

    func copyDraft() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcriptDraft, forType: .string)
    }

    func togglePlayback(_ entry: TranscriptionHistoryEntry) {
        do {
            if audioPlayer?.isPlaying == true { audioPlayer?.pause(); return }
            if audioPlayer == nil { audioPlayer = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: entry.audioPath)) }
            audioPlayer?.play()
            errorMessage = nil
        } catch { errorMessage = "無法播放來源音訊：\(error.localizedDescription)" }
    }

    func seek(to segment: TranscriptionSegment, index: Int, in entry: TranscriptionHistoryEntry) {
        do {
            let audioURL = URL(fileURLWithPath: entry.audioPath)
            if audioPlayer == nil || audioPlayer?.url != audioURL {
                audioPlayer = try AVAudioPlayer(contentsOf: audioURL)
            }
            audioPlayer?.currentTime = segment.start
            audioPlayer?.play()
            playingSegmentIndex = index
            errorMessage = nil
            startPlaybackPolling(entry)
        } catch { errorMessage = "無法播放來源音訊：\(error.localizedDescription)" }
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

    func export(_ entry: TranscriptionHistoryEntry, as format: TranscriptionExportFormat) {
        do {
            let content = try format.render(entry: entry, editedText: transcriptDraft)
            exportDocument = TranscriptionExportDocument(content: content)
            let stem = URL(fileURLWithPath: entry.audioPath).deletingPathExtension().lastPathComponent
            exportFilename = "\(stem).\(format.filenameExtension)"
            isExporting = true
            errorMessage = nil
        } catch { errorMessage = "Export failed: \(error.localizedDescription)" }
    }
}
