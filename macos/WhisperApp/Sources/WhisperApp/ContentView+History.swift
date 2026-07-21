import SwiftUI

extension ContentView {
    var historySection: some View {
        DisclosureGroup("轉錄歷史（\(history.entries.count)）") {
            if history.entries.isEmpty {
                ContentUnavailableView("尚無轉錄歷史", systemImage: "clock.arrow.circlepath")
                    .frame(height: 120)
            } else {
                VStack(spacing: 0) {
                    HStack {
                        TextField("搜尋檔名或逐字稿", text: $historyQuery)
                            .textFieldStyle(.roundedBorder)
                        Picker("保留", selection: Binding(
                            get: { settings.historyRetention },
                            set: { updateHistoryRetention($0) }
                        )) {
                            ForEach(AppSettingsStore.supportedHistoryRetentions, id: \.self) { Text("\($0) 筆") }
                        }
                        Button("清除全部", role: .destructive) { clearHistory() }
                    }
                    ForEach(filteredHistory.prefix(50)) { entry in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(URL(fileURLWithPath: entry.audioPath).lastPathComponent).font(.headline)
                                Spacer()
                                Text("\(entry.model) · \(entry.completedAt.formatted())")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text(entry.text).lineLimit(3).textSelection(.enabled)
                            HStack {
                                Button("載入結果") { restore(entry) }
                                Button("發布會議筆記至 Obsidian") { exportToObsidian(entry) }
                                    .disabled(settings.obsidianVaultPath.isEmpty)
                                Button("發布至 Notion") { publishToNotion(entry) }
                                    .disabled(settings.notionPageID.isEmpty || notionUploadInProgress
                                              || settings.isNotionOutcomeAmbiguous(entryID: entry.id))
                                if settings.isNotionOutcomeAmbiguous(entryID: entry.id) && !notionUploadInProgress {
                                    Button("已確認 Notion，允許重試") {
                                        settings.clearNotionOutcomeAmbiguous(entryID: entry.id)
                                        notionStatus = "已解除重試鎖定"
                                    }
                                }
                                Spacer()
                                Button("刪除", role: .destructive) { removeHistory(entry) }
                            }
                        }
                        .padding(.vertical, 10)
                        Divider()
                    }
                }
            }
        }
        .tint(DaylightPalette.accentActive)
        .cardStyle()
    }

    var vocabularySection: some View {
        DisclosureGroup("專有詞庫（啟用 \(vocabulary.terms.filter(\.isEnabled).count)）") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("新增常用人名、產品或術語", text: $newVocabularyTerm)
                    Button("加入") { addVocabularyTerm() }
                        .disabled(newVocabularyTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ForEach(vocabulary.terms) { term in
                    HStack {
                        Toggle(term.value, isOn: Binding(
                            get: { term.isEnabled },
                            set: { _ in toggleVocabularyTerm(term) }
                        ))
                        Spacer()
                        Button("刪除", role: .destructive) { removeVocabularyTerm(term) }
                    }
                }
            }.padding(.top, 8)
        }
        .tint(DaylightPalette.accentActive)
        .cardStyle()
    }

    var filteredHistory: [TranscriptionHistoryEntry] {
        let query = historyQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return history.entries }
        return history.entries.filter {
            $0.text.localizedCaseInsensitiveContains(query)
                || URL(fileURLWithPath: $0.audioPath).lastPathComponent.localizedCaseInsensitiveContains(query)
        }
    }

    func addVocabularyTerm() {
        do { try vocabulary.add(newVocabularyTerm); newVocabularyTerm = ""; errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }

    func toggleVocabularyTerm(_ term: VocabularyTerm) {
        do { try vocabulary.toggle(term); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }

    func removeVocabularyTerm(_ term: VocabularyTerm) {
        do { try vocabulary.remove(term); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }

    func removeHistory(_ entry: TranscriptionHistoryEntry) {
        do {
            try historyDeletion.delete(entry)
            if currentEntryID == entry.id {
                currentEntryID = nil
                transientEntry = nil
                transcriptDraft = ""
                isDraftDirty = false
                switchSummaryWorkspace()
            }
            pendingSummaryDrafts[entry.id] = nil
            errorMessage = nil
        }
        catch { errorMessage = error.localizedDescription }
    }

    func clearHistory() {
        do {
            let deleted = try historyDeletion.clearAll()
            currentEntryID = nil
            transientEntry = nil
            transcriptDraft = ""
            isDraftDirty = false
            switchSummaryWorkspace()
            for id in deleted { pendingSummaryDrafts[id] = nil }
            errorMessage = nil
        }
        catch { errorMessage = error.localizedDescription }
    }

    func updateHistoryRetention(_ value: Int) {
        do {
            let deleted = try historyDeletion.updateRetention(value)
            settings.historyRetention = value
            if let currentEntryID, deleted.contains(currentEntryID) {
                self.currentEntryID = nil
                transcriptDraft = ""
                isDraftDirty = false
                switchSummaryWorkspace()
            }
            for id in deleted { pendingSummaryDrafts[id] = nil }
            errorMessage = nil
        }
        catch { errorMessage = error.localizedDescription }
    }

    func exportToObsidian(_ entry: TranscriptionHistoryEntry) {
        do {
            let output = try ObsidianExportService().export(
                entry,
                summary: summaries.summary(for: entry.id),
                existingPath: entry.obsidianNotePath.map { URL(fileURLWithPath: $0) },
                to: URL(fileURLWithPath: settings.obsidianVaultPath, isDirectory: true)
            )
            // Best-effort: the note is already written; a failure here just means the next
            // publish won't find this path and will create a new note instead of updating it.
            try? history.updateObsidianNotePath(id: entry.id, path: output.path)
            obsidianStatus = "Saved to Obsidian: \(output.lastPathComponent)"
        } catch {
            obsidianStatus = "Obsidian export failed: \(error.localizedDescription)"
        }
    }

    func publishToNotion(_ entry: TranscriptionHistoryEntry) {
        guard !notionUploadInProgress,
              !settings.isNotionOutcomeAmbiguous(entryID: entry.id) else { return }
        notionUploadInProgress = true
        notionStatus = "Publishing to Notion…"
        // Optimistically lock before the request is even sent, so a crash mid-request still
        // leaves the entry locked on relaunch instead of risking a duplicate create/append.
        settings.markNotionOutcomeAmbiguous(entryID: entry.id)
        Task {
            defer { notionUploadInProgress = false }
            do {
                guard let token = try NotionCredentialStore().load() else {
                    throw NotionClientError.missingToken
                }
                let childPageID = try await NotionClient().publish(
                    entry, summary: summaries.summary(for: entry.id),
                    parentPageID: settings.notionPageID,
                    existingChildPageID: entry.notionChildPageID, token: token
                )
                // Best-effort: the page is already written; a failure here just means the next
                // publish won't find this id and will create a new child page instead of updating
                // it. Surface it (rather than a silent try?) so a persistently failing disk write
                // doesn't look like a normal success on every future publish of this entry.
                do {
                    try history.updateNotionChildPageID(id: entry.id, pageID: childPageID)
                    notionStatus = "Published to Notion"
                } catch {
                    notionStatus = "Published to Notion, but failed to remember the page for next time: \(error.localizedDescription)"
                }
                settings.clearNotionOutcomeAmbiguous(entryID: entry.id)
            } catch NotionClientError.ambiguousOutcome {
                notionStatus = "Notion may have accepted this entry. Verify the page before enabling retry."
            } catch {
                // NotionCredentialError (Keychain read failure) always happens before any
                // network request is made, so it's always safe to clear like NotionClientError
                // cases where clearsAmbiguousLock is true.
                if error is NotionCredentialError
                    || (error as? NotionClientError)?.clearsAmbiguousLock == true {
                    settings.clearNotionOutcomeAmbiguous(entryID: entry.id)
                }
                notionStatus = "Notion upload failed: \(error.localizedDescription)"
            }
        }
    }
}
