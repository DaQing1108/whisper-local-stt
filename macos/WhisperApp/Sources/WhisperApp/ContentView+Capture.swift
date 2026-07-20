import SwiftUI

extension ContentView {
    var captureCard: some View {
        VStack(spacing: 18) {
            Image(systemName: audioMode.symbol)
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(isPrimaryRecording ? DaylightPalette.accentRecord : DaylightPalette.accentActive)
                .symbolEffect(.pulse, isActive: isPrimaryRecording)
                .frame(height: 54)
            VStack(spacing: 4) {
                Text(primaryStatusText).font(.headline)
                Text(modeHelpText).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if isPrimaryRecording, let captureStartedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Self.elapsedString(from: captureStartedAt, to: context.date))
                        .font(.system(.title3, design: .monospaced).monospacedDigit())
                        .accessibilityLabel("Recording elapsed time")
                }
                if audioMode == .standard {
                    ProgressView(value: recording.microphone.audioLevel)
                        .progressViewStyle(.linear)
                        .tint(DaylightPalette.accentRecord)
                        .accessibilityLabel("Audio input level")
                        .accessibilityValue("\(Int(recording.microphone.audioLevel * 100)) percent")
                }
            }
            Button(action: primaryCaptureAction) {
                Label(primaryButtonLabel, systemImage: isPrimaryRecording ? "stop.fill" : audioMode.symbol)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(isPrimaryRecording ? DaylightPalette.accentRecord : DaylightPalette.accentActive)
            .controlSize(.large)
            .disabled(!primaryActionEnabled)
        }
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .cardStyle()
    }

    var quickSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("快速設定").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 12) {
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
                        ForEach(AppSettingsStore.supportedModels, id: \.self) { Text($0) }
                    }
                    Menu("語言快速選擇") {
                        Button("Auto") { settings.language = "" }
                        Button("中文 / 繁中") { settings.language = "zh" }
                        Button("English") { settings.language = "en" }
                        Button("Japanese") { settings.language = "ja" }
                    }
                    TextField("Auto 或 ISO code（zh / en / ja）", text: Binding(
                        get: { settings.language }, set: { settings.language = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Label(worker.modelReadinessMessage, systemImage: modelReadinessSymbol)
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("檢查模型") { checkModelStatus() }
                        .disabled(worker.state != .ready || worker.modelOperationInProgress)
                    Button("下載 / 驗證模型 Cache") { warmupSelectedModel() }
                        .disabled(worker.state != .ready || worker.activeRequestID != nil || worker.modelOperationInProgress)
                }
                HStack {
                    Picker("領域", selection: Binding(
                        get: { settings.domain }, set: { settings.domain = $0 }
                    )) {
                        ForEach(AppSettingsStore.supportedDomains, id: \.self) { Text($0.capitalized) }
                    }
                    TextField("本次專有詞（逗號分隔）", text: Binding(
                        get: { settings.extraTerms }, set: { settings.extraTerms = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
                if audioMode == .system || audioMode == .mixed {
                    HStack {
                        Label(systemAudioPermission.statusMessage, systemImage: "rectangle.inset.filled.and.person.filled")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if systemAudioPermission.status != .granted {
                            Button("授予螢幕錄製權限") { _ = systemAudioPermission.requestAccess() }
                        }
                    }
                }
            }
            .padding(.top, 4)
        }
        .cardStyle()
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
                        Text(item.status.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                    }
                    if let message = item.message {
                        Text(message).font(.caption).foregroundStyle(.red)
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
