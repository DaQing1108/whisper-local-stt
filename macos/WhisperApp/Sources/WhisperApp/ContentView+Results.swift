import SwiftUI
import AVFoundation

extension ContentView {
    var resultsWorkspace: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("本次轉錄結果").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
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
                HStack {
                    Button("儲存修改") { saveDraft() }.disabled(currentEntryID == nil)
                    Button("複製") { copyDraft() }.disabled(transcriptDraft.isEmpty)
                    Button("清空") { transcriptDraft = ""; isDraftDirty = true }.disabled(transcriptDraft.isEmpty)
                    if let entry = currentEntry {
                        Button(audioPlayer?.isPlaying == true ? "暫停音訊" : "播放音訊") { togglePlayback(entry) }
                        Menu("Export") {
                            ForEach(TranscriptionExportFormat.allCases) { format in
                                Button(format.rawValue) { export(entry, as: format) }
                                    .disabled(format == .srt && entry.segments.isEmpty)
                            }
                        }
                    }
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
        .cardStyle()
    }

    var summaryWorkspace: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AI 會議摘要").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
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
        .cardStyle()
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
