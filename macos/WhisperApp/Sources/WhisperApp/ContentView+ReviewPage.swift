import SwiftUI

/// Post-meeting review page: header (name, date, length, speakers, 匯出, ⋯), full-width tabs,
/// and a playback bar pinned to the bottom. Only the tab content scrolls.
extension ContentView {
    var reviewPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            reviewHeader
            PillSegmentedControl(
                options: WorkspaceTab.allCases,
                selection: $selectedWorkspaceTab,
                accessibilityLabel: "檢視頁分頁"
            ) { tab in Text(tabTitle(tab)) }
            Group {
                switch selectedWorkspaceTab {
                case .transcript: transcriptTab
                case .summary: ScrollView { summaryContent.padding(.trailing, 4) }
                case .vocabulary: ScrollView { vocabularySuggestionsTab.padding(.trailing, 4) }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            if let entry = currentEntry {
                Divider()
                playbackBar(entry)
            }
        }
        .sheet(isPresented: $isDiarizationSheetPresented) { diarizationSheet }
        // Read the real audio length once per loaded record (file header only), cached in view state.
        .task(id: currentEntry?.audioPath) {
            guard let path = currentEntry?.audioPath, actualAudioSeconds[path] == nil else { return }
            let seconds = await Task.detached(priority: .userInitiated) {
                ReviewHeaderRules.sessionAudioDuration(atPath: path)
            }.value
            if let seconds { actualAudioSeconds[path] = seconds }
        }
    }

    /// The one length source for the header, the playback bar's total and the scrubber range.
    func reviewDuration(of entry: TranscriptionHistoryEntry) -> TimeInterval? {
        ReviewHeaderRules.durationSeconds(of: entry, actualAudioSeconds: actualAudioSeconds[entry.audioPath])
    }

    func tabTitle(_ tab: WorkspaceTab) -> String {
        guard tab == .vocabulary, vocabularySuggestions.sourceTranscriptionID == currentEntry?.id,
              !vocabularySuggestions.suggestions.isEmpty else { return tab.title }
        return "\(tab.title) \(vocabularySuggestions.suggestions.count)"
    }

    // MARK: - Header

    private var reviewHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                TextField("會議名稱", text: $meetingTitle)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .focused($isMeetingTitleFocused)
                    .onSubmit { commitMeetingTitle() }
                    .onChange(of: isMeetingTitleFocused) { _, focused in if !focused { commitMeetingTitle() } }
                    .disabled(currentEntryID == nil)
                if let entry = currentEntry {
                    Text(headerFacts(entry)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .layoutPriority(0)
            Spacer(minLength: 8)
            if let entry = currentEntry {
                exportMenu(entry)
                moreActionsMenu(entry)
            }
        }
    }

    private func headerFacts(_ entry: TranscriptionHistoryEntry) -> String {
        var facts = [ReviewHeaderRules.dateText(entry.completedAt)]
        if let duration = reviewDuration(of: entry) { facts.append(PlaybackRules.timeText(duration)) }
        let speakers = ReviewHeaderRules.speakerCount(entry.segments)
        if speakers > 0 { facts.append("\(speakers) 位講者") }
        return facts.joined(separator: " · ")
    }

    /// Saves the header name through MeetingSummaryStore.saveTitle. Blank restores the default name.
    /// Unchanged names are not written, so merely viewing a record never creates a summary record.
    func commitMeetingTitle() {
        guard let entry = currentEntry, currentEntryID == entry.id else { return }
        let savedTitle = currentSummary?.meetingTitle
        let defaultTitle = ReviewHeaderRules.defaultTitle(for: entry)
        guard let title = ReviewHeaderRules.titleToSave(
            typed: meetingTitle, savedTitle: savedTitle, defaultTitle: defaultTitle
        ) else {
            meetingTitle = savedTitle ?? defaultTitle
            return
        }
        meetingTitle = title
        do {
            try summaries.saveTitle(transcriptionID: entry.id, title: title)
            if var pending = pendingSummaryDrafts[entry.id] {
                pending.title = title
                pendingSummaryDrafts[entry.id] = pending
            }
            errorMessage = nil
        } catch { errorMessage = "會議名稱儲存失敗：\(error.localizedDescription)" }
    }

    private func exportMenu(_ entry: TranscriptionHistoryEntry) -> some View {
        Menu("匯出") {
            ForEach(TranscriptionExportFormat.allCases) { format in
                Button(format.rawValue) { export(entry, as: format) }
                    .disabled(format == .srt && entry.segments.isEmpty)
            }
        }
        .menuStyle(.button)
        .fixedSize()
    }

    /// Secondary actions; visibility and disabled conditions match the buttons they replace.
    private func moreActionsMenu(_ entry: TranscriptionHistoryEntry) -> some View {
        Menu {
            Button("辨識講者…") { isDiarizationSheetPresented = true }
                .disabled(entry.segments.isEmpty || worker.diarizationOperationInProgress || worker.activeRequestID != nil)
            if !SpeakerRename.extractSpeakerLabels(from: transcriptDraft).isEmpty {
                Button("重新命名講者") { openSpeakerRenameSheet() }
            }
            if !worker.diarizationAvailable && worker.diarizationStatus != "ready" {
                Button(worker.diarizationStatus == "loading" ? "下載模型中…" : "下載講者辨識模型") {
                    triggerDiarizationWarmup()
                }
                .disabled(worker.diarizationOperationInProgress || worker.activeRequestID != nil)
            }
            if entry.segments.isEmpty && FileManager.default.fileExists(atPath: entry.audioPath) {
                Button("重新轉錄") { retranscribe(entry) }
                    .disabled(worker.activeRequestID != nil
                              || worker.diarizationOperationInProgress
                              || worker.modelOperationInProgress)
            }
            Divider()
            Button("複製全文") { copyDraft() }.disabled(transcriptDraft.isEmpty)
            if TranscriptViewRules.showsClearButton(isEditing: isEditingTranscript) {
                Button("清空文字") { transcriptDraft = ""; isDraftDirty = true }.disabled(transcriptDraft.isEmpty)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("更多動作")
        .accessibilityLabel("更多動作")
    }

    private var diarizationSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("辨識講者").font(.headline)
            TextField("已知講者人數（留空＝自動）", text: $knownSpeakerCount)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .disabled(worker.diarizationOperationInProgress || worker.activeRequestID != nil)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { isDiarizationSheetPresented = false }
                Button("開始辨識") {
                    isDiarizationSheetPresented = false
                    if let entry = currentEntry { triggerDiarization(entry) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled((currentEntry?.segments.isEmpty ?? true)
                          || worker.diarizationOperationInProgress || worker.activeRequestID != nil)
            }
        }
        .padding(20)
    }

    // MARK: - Transcript tab

    private var transcriptTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            if TranscriptViewRules.showsJobControls(
                hasActiveRequest: worker.activeRequestID != nil,
                isChunkedCaptureActive: liveOwnsMicrophone || mixedAudioOwnsCapture
            ) {
                HStack {
                    Text(StatusTextRules.jobStatus(worker.jobStatus)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("取消", role: .destructive) { try? worker.cancel() }
                        .disabled(worker.activeJobID == nil)
                }
                ProgressView(value: worker.progress)
            }
            HStack {
                Text(worker.llmPunctuationEnabled ? "✨ 語意校對：已啟用" : "🔇 語意校對：未設定 API Key，已跳過")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if showsTranscriptSearch { transcriptSearchBar }
            }
            if mixedAudioRecording.isDraining {
                Text("⏳ 混音錄音已停止，最後片段仍在轉錄中…")
                    .font(.caption).foregroundStyle(.orange)
            }
            transcriptBody.frame(maxHeight: .infinity)
            HStack {
                Button(TranscriptViewRules.editToggleLabel(isEditing: isEditingTranscript)) {
                    isEditingTranscript.toggle()
                }
                .buttonStyle(.bordered)
                Button("儲存修改") { saveDraft() }.disabled(currentEntryID == nil)
                    .buttonStyle(.bordered)
                if worker.diarizationStatus == "processing" {
                    ProgressView().controlSize(.small)
                    Text("講者辨識進行中，可能需要數十秒…").font(.caption).foregroundStyle(.secondary)
                }
                if let diarizationFailureMessage = worker.diarizationFailureMessage, worker.diarizationStatus == "failed" {
                    Text(diarizationFailureMessage).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }
        }
        .tint(DaylightPalette.accentActive)
    }

    /// Search only applies to the timecode list (reading mode).
    private var showsTranscriptSearch: Bool {
        TranscriptViewRules.body(
            isEditing: isEditingTranscript,
            hasSegments: !(currentEntry?.segments.isEmpty ?? true),
            draftDiverged: transcriptDraftDiverged
        ) == .segmentList
    }

    var transcriptSearchMatches: [Int] {
        TranscriptSearch.matches(in: currentEntry?.segments ?? [], query: transcriptSearchQuery)
    }

    /// Segment index of the current search hit (scroll target), if any.
    var transcriptSearchFocusIndex: Int? {
        let matches = transcriptSearchMatches
        guard let position = transcriptSearchPosition, matches.indices.contains(position) else { return nil }
        return matches[position]
    }

    private var transcriptSearchBar: some View {
        let matches = transcriptSearchMatches
        return HStack(spacing: 6) {
            TextField("搜尋逐字稿", text: $transcriptSearchQuery)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .onChange(of: transcriptSearchQuery) { _, _ in
                    transcriptSearchPosition = transcriptSearchMatches.isEmpty ? nil : 0
                }
                .onSubmit { stepTranscriptSearch(forward: true) }
            if let counter = TranscriptSearch.counterText(
                position: transcriptSearchPosition, matchCount: matches.count, query: transcriptSearchQuery
            ) {
                Text(counter).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Button { stepTranscriptSearch(forward: false) } label: { Image(systemName: "chevron.up") }
                .disabled(matches.isEmpty).help("上一個")
            Button { stepTranscriptSearch(forward: true) } label: { Image(systemName: "chevron.down") }
                .disabled(matches.isEmpty).help("下一個")
        }
        .buttonStyle(.borderless)
    }

    private func stepTranscriptSearch(forward: Bool) {
        transcriptSearchPosition = TranscriptSearch.step(
            from: transcriptSearchPosition, matchCount: transcriptSearchMatches.count, forward: forward
        )
    }
}
