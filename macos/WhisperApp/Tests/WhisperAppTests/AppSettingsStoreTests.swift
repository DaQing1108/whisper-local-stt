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
    func rejectsUnknownPersistedModel() {
        let suite = "WhisperAppTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("invented", forKey: AppSettingsStore.modelKey)

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
