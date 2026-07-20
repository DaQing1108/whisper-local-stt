import Foundation
import Observation

@MainActor
@Observable
final class AppSettingsStore {
    static let modelKey = "whisper.defaultModel"
    static let languageKey = "whisper.language"
    static let domainKey = "whisper.domain"
    static let extraTermsKey = "whisper.extraTerms"
    static let obsidianVaultPathKey = "whisper.obsidianVaultPath"
    static let notionPageIDKey = "whisper.notionPageID"
    static let notionAmbiguousEntryIDsKey = "whisper.notionAmbiguousEntryIDs"
    static let historyRetentionKey = "whisper.historyRetention"
    static let summaryProviderKey = "whisper.summaryProvider"
    static let audioModeKey = "whisper.audioMode"
    static let supportedModels = ["tiny", "base", "small", "medium", "large-v3"]
    // Must match whisper_core.py's DOMAIN_TERMS keys exactly, or a selection silently
    // resolves to an empty prompt server-side.
    static let supportedDomains = ["general", "media", "tech", "medical", "legal"]
    static let supportedHistoryRetentions = [50, 100, 200, 500]

    static func normalizedLanguage(_ rawValue: String) -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.range(of: #"^[a-z]{2,3}$"#, options: .regularExpression) != nil else { return "" }
        return value
    }

    private let defaults: UserDefaults
    var defaultModel: String {
        didSet {
            if Self.supportedModels.contains(defaultModel) {
                defaults.set(defaultModel, forKey: Self.modelKey)
            } else {
                defaultModel = oldValue
            }
        }
    }
    var language: String {
        didSet {
            let normalized = Self.normalizedLanguage(language)
            if language != normalized {
                language = normalized
            }
            defaults.set(normalized, forKey: Self.languageKey)
        }
    }
    var domain: String {
        didSet {
            if Self.supportedDomains.contains(domain) { defaults.set(domain, forKey: Self.domainKey) }
            else { domain = oldValue }
        }
    }
    var extraTerms: String {
        didSet { defaults.set(extraTerms.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.extraTermsKey) }
    }
    var obsidianVaultPath: String {
        didSet { defaults.set(obsidianVaultPath, forKey: Self.obsidianVaultPathKey) }
    }
    var notionPageID: String {
        didSet { defaults.set(notionPageID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.notionPageIDKey) }
    }
    private(set) var notionAmbiguousEntryIDs: Set<String>
    var historyRetention: Int {
        didSet {
            if Self.supportedHistoryRetentions.contains(historyRetention) {
                defaults.set(historyRetention, forKey: Self.historyRetentionKey)
            } else { historyRetention = oldValue }
        }
    }
    var summaryProvider: MeetingSummaryProvider {
        didSet { defaults.set(summaryProvider.rawValue, forKey: Self.summaryProviderKey) }
    }
    var audioMode: AudioInputMode {
        didSet { defaults.set(audioMode.rawValue, forKey: Self.audioModeKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedModel = defaults.string(forKey: Self.modelKey)
        defaultModel = Self.supportedModels.contains(storedModel ?? "") ? storedModel! : "base"
        language = Self.normalizedLanguage(defaults.string(forKey: Self.languageKey) ?? "")
        let storedDomain = defaults.string(forKey: Self.domainKey)
        domain = Self.supportedDomains.contains(storedDomain ?? "") ? storedDomain! : "general"
        extraTerms = defaults.string(forKey: Self.extraTermsKey) ?? ""
        obsidianVaultPath = defaults.string(forKey: Self.obsidianVaultPathKey) ?? ""
        notionPageID = defaults.string(forKey: Self.notionPageIDKey) ?? ""
        notionAmbiguousEntryIDs = Set(defaults.stringArray(forKey: Self.notionAmbiguousEntryIDsKey) ?? [])
        let retention = defaults.integer(forKey: Self.historyRetentionKey)
        historyRetention = Self.supportedHistoryRetentions.contains(retention) ? retention : 200
        summaryProvider = MeetingSummaryProvider(
            rawValue: defaults.string(forKey: Self.summaryProviderKey) ?? ""
        ) ?? .openAI
        audioMode = AudioInputMode(
            rawValue: defaults.string(forKey: Self.audioModeKey) ?? ""
        ) ?? .standard
    }

    func markNotionOutcomeAmbiguous(entryID: UUID) {
        notionAmbiguousEntryIDs.insert(entryID.uuidString)
        defaults.set(Array(notionAmbiguousEntryIDs).sorted(), forKey: Self.notionAmbiguousEntryIDsKey)
    }

    func clearNotionOutcomeAmbiguous(entryID: UUID) {
        notionAmbiguousEntryIDs.remove(entryID.uuidString)
        defaults.set(Array(notionAmbiguousEntryIDs).sorted(), forKey: Self.notionAmbiguousEntryIDsKey)
    }

    func clearNotionOutcomeAmbiguous(entryIDs: Set<UUID>) {
        for id in entryIDs { notionAmbiguousEntryIDs.remove(id.uuidString) }
        defaults.set(Array(notionAmbiguousEntryIDs).sorted(), forKey: Self.notionAmbiguousEntryIDsKey)
    }

    func isNotionOutcomeAmbiguous(entryID: UUID) -> Bool {
        notionAmbiguousEntryIDs.contains(entryID.uuidString)
    }
}
