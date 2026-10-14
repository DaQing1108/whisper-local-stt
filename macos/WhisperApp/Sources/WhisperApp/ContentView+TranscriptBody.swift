import SwiftUI

/// Transcript area: reading mode (clickable timecode list, or read-only text) and editing mode.
extension ContentView {
    var transcriptDraftDiverged: Bool {
        guard let entry = currentEntry else { return isDraftDirty }
        return TranscriptViewRules.draftDiverged(
            isDraftDirty: isDraftDirty,
            segmentsWhenEdited: segmentsWhenTranscriptEdited[entry.id],
            currentSegments: entry.segments
        )
    }

    @ViewBuilder var transcriptBody: some View {
        let diverged = transcriptDraftDiverged
        if TranscriptViewRules.showsUnsavedNotice(isEditing: isEditingTranscript, isDraftDirty: isDraftDirty) {
            Label("有未儲存的修改", systemImage: "pencil.circle")
                .font(.caption).foregroundStyle(.orange)
        } else if TranscriptViewRules.showsEditedNotice(
            isEditing: isEditingTranscript, isDraftDirty: isDraftDirty, draftDiverged: diverged
        ) {
            Label("逐字稿已手動編輯，時間碼清單暫不顯示", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
        }
        switch TranscriptViewRules.body(
            isEditing: isEditingTranscript,
            hasSegments: !(currentEntry?.segments.isEmpty ?? true),
            draftDiverged: diverged
        ) {
        case .editor:
            transcriptEditor
        case .segmentList:
            if let entry = currentEntry { segmentListView(entry) } else { transcriptReadOnlyText }
        case .readOnlyText:
            transcriptReadOnlyText
        }
    }

    /// Fills the review page; this is only the floor on very short windows.
    static let transcriptAreaMinHeight: CGFloat = 160
    static let searchMatchHighlightOpacity: Double = 0.12
    static let searchFocusHighlightOpacity: Double = 0.3

    var transcriptEditor: some View {
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
            .frame(minHeight: Self.transcriptAreaMinHeight, maxHeight: .infinity)
    }

    /// Reading mode for records without timecoded segments (older or text-only entries).
    var transcriptReadOnlyText: some View {
        ScrollView {
            Text(transcriptDraft.isEmpty ? "完成錄音或選擇音訊檔後，逐字稿會顯示在這裡。" : transcriptDraft)
                .foregroundStyle(transcriptDraft.isEmpty ? .tertiary : .primary)
                .lineSpacing(8)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(minHeight: Self.transcriptAreaMinHeight, maxHeight: .infinity)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
    }

    func segmentListView(_ entry: TranscriptionHistoryEntry) -> some View {
        let speakerColors = SpeakerColor.colorIndices(for: entry.segments)
        let searchMatches = Set(transcriptSearchMatches)
        let searchFocus = transcriptSearchFocusIndex
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(entry.segments.enumerated()), id: \.offset) { index, segment in
                        Button {
                            seek(to: segment, index: index, in: entry)
                        } label: {
                            Self.segmentText(segment, colorIndex: segment.speaker.flatMap { speakerColors[$0] })
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(
                                    Self.rowHighlight(
                                        isPlaying: index == playingSegmentIndex,
                                        isSearchFocus: index == searchFocus,
                                        isSearchMatch: searchMatches.contains(index)
                                    ),
                                    in: RoundedRectangle(cornerRadius: 4)
                                )
                        }
                        .buttonStyle(.plain)
                        .id(index)
                        .onAppear { if index == entry.segments.count - 1 { isTranscriptListAtBottom = true } }
                        .onDisappear { if index == entry.segments.count - 1 { isTranscriptListAtBottom = false } }
                    }
                }
                .padding(4)
            }
            .onChange(of: entry.segments.count) { oldCount, newCount in
                guard TranscriptViewRules.shouldAutoScroll(
                    isAtBottom: isTranscriptListAtBottom, segmentCountIncreased: newCount > oldCount
                ) else { return }
                proxy.scrollTo(newCount - 1, anchor: .bottom)
            }
            // Search「上一個／下一個」scrolls to the hit without starting playback.
            .onChange(of: searchFocus) { _, index in
                if let index { proxy.scrollTo(index, anchor: .center) }
            }
        }
        // A new record gets a fresh scroll view, so its count change never auto-scrolls it.
        .id(entry.id)
        .frame(minHeight: Self.transcriptAreaMinHeight, maxHeight: .infinity)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
    }

    /// Timecode, speaker name in its system colour, then the text in the normal colour.
    static func segmentText(_ segment: TranscriptionSegment, colorIndex: Int?) -> Text {
        let wholeSeconds = max(0, Int(segment.start.rounded(.down)))
        let timestamp = Text(String(format: "[%02d:%02d] ", wholeSeconds / 60, wholeSeconds % 60))
            .foregroundColor(.secondary)
        guard let speaker = segment.speaker else { return timestamp + Text(segment.text) }
        let color = colorIndex.map(SpeakerColor.color(forIndex:)) ?? .secondary
        return timestamp + Text("\(speaker)  ").foregroundColor(color).bold() + Text(segment.text)
    }

    static func rowHighlight(isPlaying: Bool, isSearchFocus: Bool, isSearchMatch: Bool) -> Color {
        if isPlaying { return DaylightPalette.accentActive.opacity(activeSegmentHighlightOpacity) }
        if isSearchFocus { return Color.yellow.opacity(searchFocusHighlightOpacity) }
        if isSearchMatch { return Color.yellow.opacity(searchMatchHighlightOpacity) }
        return .clear
    }
}
