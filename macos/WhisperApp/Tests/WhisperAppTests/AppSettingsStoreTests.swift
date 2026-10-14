import Foundation
import Testing
@testable import WhisperApp

@MainActor
struct AppSettingsStoreTests {
    @Test
    func persistsModelAndLanguageAcrossInstances() {
        let suite = "WhisperAppTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = AppSettingsStore(defaults: defaults)
        first.defaultModel = "small"
        first.language = "zh"
        first.domain = "media"
        first.extraTerms = "VIA, Whisper"
        first.historyRetention = 500
        first.summaryProvider = .anthropic
        first.audioMode = .mixed
        first.obsidianVaultPath = "/tmp/Vault"
        first.notionPageID = "0123456789abcdef0123456789abcdef"
        let ambiguousID = UUID()
        first.markNotionOutcomeAmbiguous(entryID: ambiguousID)

        let restored = AppSettingsStore(defaults: defaults)
        #expect(restored.defaultModel == "small")
        #expect(restored.language == "zh")
        #expect(restored.domain == "media")
        #expect(restored.extraTerms == "VIA, Whisper")
        #expect(restored.historyRetention == 500)
        #expect(restored.summaryProvider == .anthropic)
        #expect(restored.audioMode == .mixed)
        #expect(restored.obsidianVaultPath == "/tmp/Vault")
        #expect(restored.notionPageID == "0123456789abcdef0123456789abcdef")
        #expect(restored.isNotionOutcomeAmbiguous(entryID: ambiguousID))
        restored.clearNotionOutcomeAmbiguous(entryIDs: Set([ambiguousID]))
        #expect(!restored.isNotionOutcomeAmbiguous(entryID: ambiguousID))
    }

    @Test
    func acceptsAndPersistsTurboModelAsDefault() {
        let suite = "WhisperAppTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(AppSettingsStore.supportedModels.contains("large-v3-turbo"))
        let first = AppSettingsStore(defaults: defaults)
        #expect(first.defaultModel == "large-v3-turbo")
        first.defaultModel = "small"
        #expect(first.defaultModel == "small")
        first.defaultModel = "large-v3-turbo"
        #expect(first.defaultModel == "large-v3-turbo")
        #expect(AppSettingsStore(defaults: defaults).defaultModel == "large-v3-turbo")
    }

    @Test
    func displayNameLabelsTurboAndKeepsOtherModelNames() {
        #expect(AppSettingsStore.displayName(for: "large-v3-turbo") == "large-v3-turbo（快速）")
        for model in ["tiny", "base", "small", "medium"] {
            #expect(AppSettingsStore.displayName(for: model) == model)
        }
        // UI tidy round 1: large-v3 is labelled slow (it can stall on long recordings).
        #expect(AppSettingsStore.displayName(for: "large-v3") == "large-v3（較慢，長錄音可能卡住）")
    }

    @Test
    func rejectsUnknownPersistedModel() {
        let suite = "WhisperAppTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("invented", forKey: AppSettingsStore.modelKey)

        #expect(AppSettingsStore(defaults: defaults).defaultModel == "large-v3-turbo")
    }

    @Test
    func persistedBaseModelIsKeptAfterDefaultChange() {
        let suite = "WhisperAppTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        AppSettingsStore(defaults: defaults).defaultModel = "base"
        #expect(AppSettingsStore(defaults: defaults).defaultModel == "base")
    }

    @Test
    func normalizesLanguageCodesAndRejectsInvalidValues() {
        let suite = "WhisperAppTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("08", forKey: AppSettingsStore.languageKey)

        let settings = AppSettingsStore(defaults: defaults)
        #expect(settings.language == "")

        settings.language = " ZH "
        #expect(settings.language == "zh")
        #expect(defaults.string(forKey: AppSettingsStore.languageKey) == "zh")

        settings.language = "08"
        #expect(settings.language == "")
        #expect(defaults.string(forKey: AppSettingsStore.languageKey) == "")
    }

    @Test
    func rejectsUnknownPersistedDomain() {
        let suite = "WhisperAppTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("technology", forKey: AppSettingsStore.domainKey)

        #expect(AppSettingsStore(defaults: defaults).domain == "general")
    }

    @Test
    func supportedDomainsMatchWorkerPromptKeys() {
        // Must stay in sync with whisper_core.py's DOMAIN_TERMS dict keys — a mismatch
        // means a selected domain silently resolves to an empty server-side prompt.
        #expect(Set(AppSettingsStore.supportedDomains) == ["general", "media", "tech", "medical", "legal"])
    }

    @Test
    func rejectsUnknownPersistedAudioMode() {
        let suite = "WhisperAppTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("invented", forKey: AppSettingsStore.audioModeKey)

        #expect(AppSettingsStore(defaults: defaults).audioMode == .standard)
    }
}
