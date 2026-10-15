import SwiftUI
import AVFoundation

/// A completed speaker-diarization result that arrived while the draft had
/// unsaved manual edits (including a prior speaker rename), so it can't be
/// applied automatically. Drives a confirmation dialog instead of being
/// silently discarded — the previous behavior only logged an inline message
/// suggesting "複製" as a recovery path, which didn't actually work since the
/// new segments were never written anywhere the user could copy from.
struct PendingDiarizationOverwrite: Identifiable {
    let id = UUID()
    let segments: [TranscriptionSegment]
}

/// A "重新轉錄" request against an entry that's currently open in the workspace
/// with unsaved manual edits, so submitting it right away would risk the
/// completion later overwriting those edits without the user ever having
/// agreed to it. Drives a confirmation dialog before the transcribe request
/// is actually sent.
struct PendingRetranscribeOverwrite: Identifiable {
    let id = UUID()
    let entry: TranscriptionHistoryEntry
}

/// A completed "重新轉錄" result whose text is dramatically shorter than the
/// entry it would replace (per `TranscriptOverwriteGuard`). Instead of letting
/// `history.updateResult` silently overwrite a full transcript with a truncated
/// one, this drives a confirmation dialog; the store still keeps a pre-change
/// backup regardless of the user's choice here.
struct PendingRetranscribeResultOverwrite: Identifiable {
    let id = UUID()
    let entryID: UUID
    let text: String
    let segments: [TranscriptionSegment]
    let durationSeconds: Double?
}

enum WorkspaceTab: Hashable, Identifiable, CaseIterable {
    case transcript
    case summary
    case vocabulary

    var id: Self { self }

    var title: String {
        switch self {
        case .transcript: "逐字稿"
        case .summary: "AI 摘要"
        case .vocabulary: "詞彙建議"
        }
    }
}

extension ContentView {
    var workspaceContainer: some View {
        reviewPage
        .cardStyle()
        .onChange(of: worker.diarizedSegments) { _, segments in
            guard !segments.isEmpty else { return }
            guard diarizationTargetEntryID != nil, diarizationTargetEntryID == currentEntry?.id else { return }
            diarizationTargetEntryID = nil
            let rendered = Self.renderSpeakerLabeled(segments)
            guard !isDraftDirty else {
                pendingDiarizationOverwrite = PendingDiarizationOverwrite(segments: segments)
                return
            }
            if TranscriptOverwriteGuard.isDestructiveShrink(
                existingText: currentEntry?.text ?? "",
                incomingText: rendered
            ) {
                pendingDiarizationOverwrite = PendingDiarizationOverwrite(segments: segments)
                return
            }
            transcriptDraft = rendered
            isDraftDirty = true
        }
        .onDisappear { stopPlaybackPolling() }
        .confirmationDialog(
            "講者辨識已完成，但逐字稿已被手動編輯",
            isPresented: Binding(
                get: { pendingDiarizationOverwrite != nil },
                set: { isPresented in if !isPresented { pendingDiarizationOverwrite = nil } }
            ),
            presenting: pendingDiarizationOverwrite
        ) { pending in
            Button("覆蓋逐字稿，套用新結果", role: .destructive) {
                transcriptDraft = Self.renderSpeakerLabeled(pending.segments)
                isDraftDirty = true
                pendingDiarizationOverwrite = nil
            }
            Button("取消，捨棄新結果", role: .cancel) {
                pendingDiarizationOverwrite = nil
            }
        } message: { pending in
            Text("目前逐字稿 \(currentEntry?.text.count ?? 0) 字，新結果 \(Self.renderSpeakerLabeled(pending.segments).count) 字。逐字稿已被手動編輯，或新結果大幅縮水。是否要用新的講者辨識結果覆蓋？選擇取消將捨棄本次辨識結果，無法復原。")
        }
        .confirmationDialog(
            "此記錄已被手動編輯，確定要重新轉錄嗎？",
            isPresented: Binding(
                get: { pendingRetranscribeOverwrite != nil },
                set: { isPresented in if !isPresented { pendingRetranscribeOverwrite = nil } }
            ),
            presenting: pendingRetranscribeOverwrite
        ) { pending in
            Button("覆蓋，重新轉錄", role: .destructive) {
                pendingRetranscribeOverwrite = nil
                startRetranscribe(pending.entry)
            }
            Button("取消", role: .cancel) {
                pendingRetranscribeOverwrite = nil
            }
        } message: { _ in
            Text("目前逐字稿已被手動編輯（含重新命名講者）。重新轉錄完成後將覆蓋這筆記錄的內容。選擇取消將不會送出重新轉錄請求。")
        }
        .confirmationDialog(
            "重新轉錄結果比現有逐字稿短很多",
            isPresented: Binding(
                get: { pendingRetranscribeResultOverwrite != nil },
                set: { isPresented in if !isPresented { pendingRetranscribeResultOverwrite = nil } }
            ),
            presenting: pendingRetranscribeResultOverwrite
        ) { pending in
            Button("覆蓋，套用新結果", role: .destructive) {
                applyRetranscribeResultOverwrite(pending)
                pendingRetranscribeResultOverwrite = nil
            }
            Button("取消，保留現有逐字稿", role: .cancel) {
                pendingRetranscribeResultOverwrite = nil
            }
        } message: { pending in
            Text("目前逐字稿 \(history.entries.first { $0.id == pending.entryID }?.text.count ?? 0) 字，重新轉錄結果 \(pending.text.count) 字。套用後會覆蓋這筆記錄（舊內容已自動存一份備份）。選擇取消將捨棄本次重新轉錄結果，記錄維持不變。")
        }
        .sheet(item: $speakerRenameSheetData) { data in
            SpeakerRenameSheetView(
                labels: data.labels,
                onConfirm: { renames in
                    transcriptDraft = SpeakerRename.applySpeakerRenames(renames, in: transcriptDraft)
                    isDraftDirty = true
                    speakerRenameSheetData = nil
                },
                onCancel: { speakerRenameSheetData = nil }
            )
        }
    }

    static let playbackPollInterval: TimeInterval = 0.3
    static let activeSegmentHighlightOpacity: Double = 0.18

    static func renderSpeakerLabeled(_ segments: [TranscriptionSegment]) -> String {
        segments.map { segment in
            if let speaker = segment.speaker { "[\(speaker)] \(segment.text)" } else { segment.text }
        }.joined(separator: "\n")
    }

    func triggerDiarization(_ entry: TranscriptionHistoryEntry) {
        do {
            diarizationTargetEntryID = entry.id
            let numSpeakers = Int(knownSpeakerCount.trimmingCharacters(in: .whitespaces))
            try worker.diarize(audioPath: entry.audioPath, segments: entry.segments, numSpeakers: numSpeakers)
            errorMessage = nil
        } catch {
            diarizationTargetEntryID = nil
            errorMessage = "無法啟動講者辨識：\(error.localizedDescription)"
        }
    }

    func retranscribe(_ entry: TranscriptionHistoryEntry) {
        if currentEntryID == entry.id, isDraftDirty {
            pendingRetranscribeOverwrite = PendingRetranscribeOverwrite(entry: entry)
            return
        }
        startRetranscribe(entry)
    }

    private func startRetranscribe(_ entry: TranscriptionHistoryEntry) {
        do {
            retranscribeTargetEntryID = entry.id
            try worker.transcribe(
                audioURL: URL(fileURLWithPath: entry.audioPath),
                modelName: entry.model,
                language: entry.language,
                domain: entry.domain,
                extraTerms: entry.extraTerms
            )
            errorMessage = nil
        } catch {
            retranscribeTargetEntryID = nil
            errorMessage = "無法啟動重新轉錄：\(error.localizedDescription)"
        }
    }

    /// Commit a retranscribe result the user confirmed despite it shrinking the
    /// transcript. Mirrors the non-shrink completion path in
    /// `showLatestWorkerResultIfNeeded`; the store writes a backup on its own.
    func applyRetranscribeResultOverwrite(_ pending: PendingRetranscribeResultOverwrite) {
        do {
            if let updated = try history.updateResult(
                id: pending.entryID,
                text: pending.text,
                segments: pending.segments,
                durationSeconds: pending.durationSeconds,
                audioURL: nil
            ) {
                if currentEntryID == updated.id {
                    transcriptDraft = updated.text
                    isDraftDirty = false
                }
            }
            errorMessage = nil
        } catch {
            errorMessage = "History update failed: \(error.localizedDescription)"
        }
    }

    func openSpeakerRenameSheet() {
        let labels = SpeakerRename.extractSpeakerLabels(from: transcriptDraft)
        speakerRenameSheetData = SpeakerRenameSheetData(labels: labels)
    }

    func triggerDiarizationWarmup() {
        do {
            try worker.diarizationWarmup()
            errorMessage = nil
        } catch {
            errorMessage = "無法啟動模型下載：\(error.localizedDescription)"
        }
    }

    var summaryContent: some View {
        VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Picker("供應商", selection: Binding(
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
                    // A name-only record (status .empty) has no summary to describe.
                    if let summary = currentSummary, ReviewHeaderRules.hasSummaryContent(summary) {
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
                .frame(minHeight: 300, maxHeight: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                HStack {
                    Button("產生摘要") { generateSummary() }
                        .buttonStyle(.borderedProminent)
                        .tint(DaylightPalette.accentActive)
                        .disabled(currentEntryID == nil || summaryController.activeTranscriptionID != nil)
                    Button("儲存摘要修改") { saveSummaryEdit() }
                        .disabled(currentEntryID == nil || !ReviewHeaderRules.hasSummaryContent(currentSummary) || !isSummaryDirty)
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
        meetingTitle = summary?.meetingTitle ?? currentEntry.map { ReviewHeaderRules.defaultTitle(for: $0) } ?? ""
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
        if currentEntryID != entry.id {
            // Save a header name still being typed while the old record is current.
            commitMeetingTitle()
            transcriptSearchPosition = nil
            // A different record: start in reading mode, scrolled to its top.
            isEditingTranscript = false
            isTranscriptListAtBottom = false
        }
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
            if let segments = currentEntry?.segments { segmentsWhenTranscriptEdited[currentEntryID] = segments }
            isDraftDirty = false
            errorMessage = nil
        }
        catch { errorMessage = error.localizedDescription }
    }

    func showLatestWorkerResultIfNeeded() {
        guard let completed = worker.latestCompletedTranscription else { return }
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
        if liveRecording.acceptCompletedChunk(
            completed.audioURL,
            text: completed.text,
            segments: completed.segments,
            durationSeconds: completed.durationSeconds
        ) {
            presentNextCompletedResult = false
            do {
                let entry: TranscriptionHistoryEntry
                if let id = liveHistoryEntryID,
                   // Live mode has no merged full-session audio file — only per-chunk WAVs — so
                   // audioURL is intentionally omitted here to keep audioPath pinned to the first
                   // chunk rather than drifting to whichever chunk completed most recently, which
                   // would silently point later segments' seek offsets at the wrong audio file.
                   let updated = try history.updateResult(
                       id: id,
                       text: liveRecording.transcriptText,
                       segments: liveRecording.transcriptSegments,
                       durationSeconds: liveRecording.transcriptDurationSeconds
                   ) {
                    entry = updated
                } else {
                    entry = try history.recordCompleted(
                        audioURL: completed.audioURL,
                        model: completed.modelName,
                        language: completed.language,
                        text: liveRecording.transcriptText,
                        segments: liveRecording.transcriptSegments,
                        durationSeconds: liveRecording.transcriptDurationSeconds,
                        domain: completed.domain,
                        extraTerms: completed.extraTerms
                    )
                }
                liveHistoryEntryID = entry.id
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
                    text: liveRecording.transcriptText,
                    segments: liveRecording.transcriptSegments,
                    durationSeconds: liveRecording.transcriptDurationSeconds,
                    domain: completed.domain,
                    extraTerms: completed.extraTerms
                )
                transcriptDraft = liveRecording.transcriptText
                isDraftDirty = false
                errorMessage = "History update failed: \(error.localizedDescription)"
            }
            return
        }
        if let targetID = retranscribeTargetEntryID {
            retranscribeTargetEntryID = nil
            let existing = history.entries.first { $0.id == targetID }
            if let existing, TranscriptOverwriteGuard.isDestructiveShrink(
                existingText: existing.text,
                incomingText: completed.text
            ) {
                pendingRetranscribeResultOverwrite = PendingRetranscribeResultOverwrite(
                    entryID: targetID,
                    text: completed.text,
                    segments: completed.segments,
                    durationSeconds: completed.durationSeconds
                )
                return
            }
            do {
                if let updated = try history.updateResult(
                    id: targetID,
                    text: completed.text,
                    segments: completed.segments,
                    durationSeconds: completed.durationSeconds,
                    audioURL: nil
                ) {
                    if currentEntryID == updated.id {
                        transcriptDraft = updated.text
                        isDraftDirty = false
                    }
                }
                errorMessage = nil
            } catch {
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

    func export(_ entry: TranscriptionHistoryEntry, as format: TranscriptionExportFormat) {
        do {
            let content = try format.render(entry: entry, editedText: transcriptDraft)
            exportDocument = TranscriptionExportDocument(content: content)
            let title = summaries.summary(for: entry.id)?.meetingTitle ?? ReviewHeaderRules.defaultTitle(for: entry)
            exportFilename = "\(ReviewHeaderRules.fileNameStem(for: title)).\(format.filenameExtension)"
            isExporting = true
            errorMessage = nil
        } catch { errorMessage = "Export failed: \(error.localizedDescription)" }
    }
}
