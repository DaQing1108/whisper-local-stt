import SwiftUI

extension ContentView {
    var obsidianNotionSettings: some View {
        DisclosureGroup("Obsidian‧Notion") {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("發布目的地") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Button("選擇 Obsidian Vault…") { isChoosingObsidianVault = true }
                            Text(settings.obsidianVaultPath.isEmpty ? "尚未設定" : settings.obsidianVaultPath)
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                        SecureField("Notion Integration token", text: $notionToken)
                        TextField("Notion destination page ID", text: Binding(
                            get: { settings.notionPageID }, set: { settings.notionPageID = $0 }
                        ))
                        Button("將 Notion token 儲存至 Keychain") { saveNotionToken() }
                            .disabled(notionToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .padding(.top, 10)
        }
        .tint(DaylightPalette.accentActive)
        .cardStyle()
    }

    var appPreferences: some View {
        DisclosureGroup("偏好設定") {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("模型") {
                    HStack {
                        Label(StatusTextRules.modelReadiness(worker.modelReadiness), systemImage: modelReadinessSymbol)
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("檢查模型") { checkModelStatus() }
                            .disabled(worker.state != .ready || worker.modelOperationInProgress)
                        Button("下載／驗證模型") { warmupSelectedModel() }
                            .disabled(worker.state != .ready || worker.activeRequestID != nil || worker.modelOperationInProgress)
                    }
                }
                GroupBox("轉錄引擎") {
                    HStack {
                        Button("啟動轉錄引擎") { startWorker() }.disabled(worker.state != .stopped)
                        Button("停止轉錄引擎") { worker.stop() }.disabled(worker.state == .stopped || liveOwnsWorker)
                        Spacer()
                        Button("檢查說話者分離能力") {
                            do { try worker.requestCapabilities(); errorMessage = nil }
                            catch { errorMessage = error.localizedDescription }
                        }.disabled(worker.state != .ready)
                    }
                }
                GroupBox("AI 摘要金鑰") {
                    VStack(alignment: .leading, spacing: 8) {
                        SecureField("OpenAI API key（僅存 Keychain）", text: $openAIAPIKey)
                        Button("將 OpenAI key 儲存至 Keychain") { saveOpenAIKey() }
                            .disabled(openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        SecureField("Anthropic API key（僅存 Keychain）", text: $anthropicAPIKey)
                        Button("將 Anthropic key 儲存至 Keychain") { saveAnthropicKey() }
                            .disabled(anthropicAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                HStack {
                    Button("檢查更新…") { updates.checkForUpdates() }.disabled(!updates.canCheckForUpdates)
                    Text(updates.statusMessage).font(.caption).foregroundStyle(.secondary)
                }
                if !worker.diagnostics.isEmpty {
                    DisclosureGroup("診斷資訊") {
                        Text(worker.diagnostics).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                GroupBox("關於") {
                    HStack {
                        Text("App 版本")
                        Spacer()
                        Text(AppIdentity.versionString).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 10)
        }
        .tint(DaylightPalette.accentActive)
        .cardStyle()
    }

    func saveOpenAIKey() {
        do {
            try LLMCredentialStore().save(apiKey: openAIAPIKey)
            openAIAPIKey = ""
            errorMessage = nil
        } catch { errorMessage = "OpenAI 金鑰儲存失敗：\(error.localizedDescription)" }
    }

    func saveAnthropicKey() {
        do {
            try LLMCredentialStore(provider: .anthropic).save(apiKey: anthropicAPIKey)
            anthropicAPIKey = ""
            errorMessage = nil
        } catch { errorMessage = "Anthropic 金鑰儲存失敗：\(error.localizedDescription)" }
    }

    func saveNotionToken() {
        do {
            try NotionCredentialStore().save(token: notionToken)
            notionToken = ""
            notionStatus = "Notion token 已儲存至 Keychain"
        } catch {
            notionStatus = "Notion token 儲存失敗：\(error.localizedDescription)"
        }
    }

    func startWorker() {
        do {
            try worker.start(configuration: WorkerLaunchConfiguration.discover())
            errorMessage = nil
        } catch {
            errorMessage = "無法啟動轉錄引擎：\(error.localizedDescription)"
        }
    }
}
