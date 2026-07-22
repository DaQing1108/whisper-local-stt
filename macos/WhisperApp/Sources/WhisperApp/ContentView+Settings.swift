import SwiftUI

extension ContentView {
    var advancedSettings: some View {
        DisclosureGroup("進階設定與整合") {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("Worker") {
                    HStack {
                        Button("啟動 Worker") { startWorker() }.disabled(worker.state != .stopped)
                        Button("停止 Worker") { worker.stop() }.disabled(worker.state == .stopped || liveOwnsWorker)
                        Spacer()
                        Button("檢查說話者分離能力") {
                            do { try worker.requestCapabilities(); errorMessage = nil }
                            catch { errorMessage = error.localizedDescription }
                        }.disabled(worker.state != .ready)
                    }
                }
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
                        Divider()
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
        } catch { errorMessage = "OpenAI credential error: \(error.localizedDescription)" }
    }

    func saveAnthropicKey() {
        do {
            try LLMCredentialStore(provider: .anthropic).save(apiKey: anthropicAPIKey)
            anthropicAPIKey = ""
            errorMessage = nil
        } catch { errorMessage = "Anthropic credential error: \(error.localizedDescription)" }
    }

    func saveNotionToken() {
        do {
            try NotionCredentialStore().save(token: notionToken)
            notionToken = ""
            notionStatus = "Notion token saved in Keychain"
        } catch {
            notionStatus = "Notion credential error: \(error.localizedDescription)"
        }
    }

    func startWorker() {
        do {
            try worker.start(configuration: WorkerLaunchConfiguration.discover())
            errorMessage = nil
        } catch {
            errorMessage = "Cannot start Worker: \(error.localizedDescription)"
        }
    }
}
