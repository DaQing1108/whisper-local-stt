import SwiftUI

extension ContentView {
    var compactControlBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            controlBarRow
            if let notice = CaptureUIRules.transcriptionDeferralNotice(
                mode: audioMode,
                isRecordingOrStarting: anyCaptureActive,
                diarizationInProgress: worker.diarizationOperationInProgress,
                modelOperationInProgress: worker.modelOperationInProgress
            ) {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            ForEach(inputSilenceWarnings, id: \.self) { warning in
                Label(warning, systemImage: "speaker.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .task(id: audioMode == .mixed && mixedAudioRecording.state == .recording) {
            await monitorMixedInputLevels()
        }
    }

    /// Samples the mixed recorder's two read-only input levels while recording, for the meters
    /// and the「持續沒有聲音」hint. Restarted (and so reset to zero) whenever recording starts/stops.
    private func monitorMixedInputLevels() async {
        inputSilence.reset()
        inputSilenceWarnings = []
        mixedMicrophoneLevel = 0
        mixedSystemLevel = 0
        while !Task.isCancelled, audioMode == .mixed, mixedAudioRecording.state == .recording {
            let microphone = settings.includeMicrophoneInMixedMode ? mixedAudioRecording.microphoneLevel : nil
            let system = mixedAudioRecording.systemLevel
            mixedMicrophoneLevel = microphone ?? 0
            mixedSystemLevel = system
            let now = Date()
            inputSilence.record(microphone: microphone, system: system, at: now)
            let warnings = inputSilence.warnings(at: now)
            if warnings != inputSilenceWarnings { inputSilenceWarnings = warnings }
            try? await Task.sleep(for: Self.inputLevelSampleInterval)
        }
    }

    private static let inputLevelSampleInterval: Duration = .milliseconds(200)

    @ViewBuilder private var mixedInputMeters: some View {
        HStack(spacing: 8) {
            if settings.includeMicrophoneInMixedMode {
                Text("麥克風").font(.caption).foregroundStyle(.secondary)
                AudioWaveformView(level: mixedMicrophoneLevel, isRecording: true).frame(width: 90)
            }
            Text("系統").font(.caption).foregroundStyle(.secondary)
            AudioWaveformView(level: mixedSystemLevel, isRecording: true).frame(width: 90)
        }
    }

    /// 「混音 · turbo · 中文 · 詞庫 220/223」— opens the same quick-settings popover as the gear.
    /// Not clickable while capturing (settings can't change mid-recording).
    private var captureSettingsSummary: some View {
        let summary = CaptureSummaryRules.summary(
            mode: audioMode, includesMicrophone: settings.includeMicrophoneInMixedMode,
            model: settings.defaultModel, language: settings.language, budget: vocabularyBudget.budget
        )
        return Button { isSettingsPopoverPresented = true } label: {
            HStack(spacing: 0) {
                Text(summary.main)
                if let vocabulary = summary.vocabulary {
                    Text(" · ")
                    Text(vocabulary).foregroundStyle(summary.isVocabularyOverLimit ? Color.orange : Color.secondary)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
        }
        .buttonStyle(.plain)
        .disabled(anyCaptureActive)
        .help("快速設定")
        .accessibilityLabel("目前設定：\(summary.main)\(summary.vocabulary.map { "，\($0)" } ?? "")")
    }

    private var controlBarRow: some View {
        HStack(spacing: 14) {
            Button(action: primaryCaptureAction) {
                Label(primaryButtonLabel, systemImage: isPrimaryRecording ? "stop.fill" : audioMode.symbol)
            }
            .buttonStyle(.borderedProminent)
            .tint(isPrimaryRecording ? DaylightPalette.accentRecord : DaylightPalette.accentActive)
            .controlSize(.large)
            .disabled(!primaryActionEnabled)
            .help(modeHelpText)
            // Never truncate the primary action; the meters and status text give way first.
            .fixedSize()
            .layoutPriority(1)

            captureSettingsSummary

            if isPrimaryRecording, let captureStartedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.elapsedString(from: captureStartedAt, to: context.date))
                        .font(.system(.body, design: .monospaced).monospacedDigit())
                        .accessibilityLabel("錄音時間")
                }
            }

            if audioMode == .mixed && isPrimaryRecording {
                mixedInputMeters
            } else {
                AudioWaveformView(
                    level: audioMode == .standard ? recording.microphone.audioLevel : 0,
                    isRecording: isPrimaryRecording
                )
                .frame(maxWidth: 180)
            }

            if let primaryStatusText {
                Text(primaryStatusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }

            Spacer()

            if let statusText { StatusBadge(text: statusText, color: statusColor) }

            Button { isSettingsPopoverPresented = true } label: {
                Image(systemName: "gearshape")
            }
            .popover(isPresented: $isSettingsPopoverPresented, arrowEdge: .top) {
                settingsPopoverContent
                    .padding(20)
                    .frame(width: 440)
            }
        }
    }

    var settingsPopoverContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("快速設定").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                PillSegmentedControl(
                    options: AudioInputMode.allCases,
                    selection: Binding(get: { settings.audioMode }, set: { settings.audioMode = $0 }),
                    isDisabled: anyCaptureActive,
                    accessibilityLabel: "音訊模式"
                ) { mode in Text(mode.title) }
                HStack {
                    Picker("模型", selection: Binding(
                        get: { settings.defaultModel }, set: { settings.defaultModel = $0; checkModelStatus() }
                    )) {
                        ForEach(AppSettingsStore.supportedModels, id: \.self) { Text(AppSettingsStore.displayName(for: $0)) }
                    }
                    Menu("語言快速選擇") {
                        Button("自動偵測") { settings.language = ""; languageDraft = "" }
                        Button("中文 / 繁中") { settings.language = "zh"; languageDraft = "zh" }
                        Button("英文") { settings.language = "en"; languageDraft = "en" }
                        Button("日文") { settings.language = "ja"; languageDraft = "ja" }
                    }
                    TextField("留空為自動偵測，或輸入語言代碼（zh / en / ja）", text: $languageDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { settings.language = languageDraft }
                        .onChange(of: settings.language, initial: true) { _, newValue in
                            if languageDraft != newValue { languageDraft = newValue }
                        }
                }
                HStack {
                    Label(StatusTextRules.modelReadiness(worker.modelReadiness), systemImage: modelReadinessSymbol)
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                HStack {
                    Picker("領域", selection: Binding(
                        get: { settings.domain }, set: { settings.domain = $0 }
                    )) {
                        ForEach(AppSettingsStore.supportedDomains, id: \.self) { Text(StatusTextRules.domainName($0)) }
                    }
                    TextField("本次專有詞（逗號分隔）", text: Binding(
                        get: { settings.extraTerms }, set: { settings.extraTerms = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
                if audioMode == .mixed {
                    Toggle("同時錄我的聲音", isOn: Binding(
                        get: { settings.includeMicrophoneInMixedMode },
                        set: { settings.includeMicrophoneInMixedMode = $0 }
                    ))
                    .disabled(anyCaptureActive)
                    HStack {
                        Label(systemAudioPermission.statusMessage, systemImage: "rectangle.inset.filled.and.person.filled")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if systemAudioPermission.status != .granted {
                            Button("授予螢幕錄製權限") { _ = systemAudioPermission.requestAccess() }
                        }
                    }
                }
                Divider()
                fileTranscription
                batchTranscription
            }
        }
    }

    var fileTranscription: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("音訊檔轉錄").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            HStack {
                Button("選擇音訊…") { isChoosingFile = true }
                Text(selectedFile?.lastPathComponent ?? "尚未選擇音訊")
                    .foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("開始轉錄") { startTranscription() }
                    .buttonStyle(.borderedProminent)
                    .tint(DaylightPalette.accentActive)
                    .disabled(worker.state != .ready || selectedFile == nil || worker.activeRequestID != nil || liveOwnsWorker)
            }
        }
        .cardStyle()
    }

    var batchTranscription: some View {
        DisclosureGroup("批次轉錄（最多 \(BatchTranscriptionController.defaultCapacity) 個檔案）") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button("選擇多個音訊…") { isChoosingBatchFiles = true }.disabled(batch.isRunning)
                    Button("開始批次") { startBatch() }
                        .buttonStyle(.borderedProminent)
                        .disabled(batch.items.isEmpty || batch.isRunning || worker.state != .ready || worker.activeRequestID != nil)
                    Button("停止待處理項目", role: .destructive) { batch.cancelPending() }
                        .disabled(!batch.isRunning)
                }
                ForEach(batch.items) { item in
                    HStack {
                        Image(systemName: batchSymbol(item.status))
                        Text(item.url.lastPathComponent).lineLimit(1)
                        Spacer()
                        Text(StatusTextRules.batchStatus(item.status)).font(.caption).foregroundStyle(.secondary)
                    }
                    if let message = item.message {
                        Text(message).font(.caption)
                            .foregroundStyle(item.status == .failed ? .red : .secondary)
                    }
                }
            }
            .padding(.top, 8)
        }
        .tint(DaylightPalette.accentActive)
        .cardStyle()
    }

    func startBatch() {
        do {
            try batch.start(
                model: settings.defaultModel, language: settings.language,
                domain: settings.domain, extraTerms: effectiveExtraTerms
            )
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func batchSymbol(_ status: BatchItemStatus) -> String {
        switch status {
        case .pending: "clock"
        case .running: "waveform"
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .cancelled: "slash.circle"
        }
    }
}
