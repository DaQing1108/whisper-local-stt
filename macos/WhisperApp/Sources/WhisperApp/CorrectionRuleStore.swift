import Foundation
import Observation

/// A user-confirmed「誤聽修正」: after transcription the Worker replaces `wrong` with `right`
/// (exact, case-sensitive; pure-ASCII `wrong` only at non-alphanumeric boundaries).
struct CorrectionRule: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var wrong: String
    var right: String
    var isEnabled: Bool
    let createdAt: Date

    init(id: UUID = UUID(), wrong: String, right: String, isEnabled: Bool = true, createdAt: Date = Date()) {
        self.id = id
        self.wrong = wrong
        self.right = right
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }
}

struct CorrectionPair: Equatable, Sendable {
    let wrong: String
    let right: String
}

enum CorrectionRuleError: Error, Equatable {
    case emptyWrong
    case emptyRight
    case wrongTooShort
    case sameAsRight
    case duplicateWrong(String)
}

extension CorrectionRuleError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .emptyWrong: "錯誤寫法不能空白"
        case .emptyRight: "正確寫法不能空白"
        case .wrongTooShort: "錯誤寫法至少要 \(CorrectionRuleStore.minimumWrongLength) 個字，避免誤換"
        case .sameAsRight: "錯誤寫法與正確寫法相同"
        case .duplicateWrong(let wrong): "「\(wrong)」已有修正規則"
        }
    }
}

@MainActor
@Observable
final class CorrectionRuleStore {
    nonisolated static let minimumWrongLength = 2

    private(set) var rules: [CorrectionRule] = []
    private(set) var loadError: String?
    private(set) var writeError: String?
    private let fileURL: URL

    /// Only enabled rules are sent with transcription requests.
    var activeCorrections: [CorrectionPair] {
        rules.filter(\.isEnabled).map { CorrectionPair(wrong: $0.wrong, right: $0.right) }
    }

    init(fileURL: URL = CorrectionRuleStore.defaultFileURL()) {
        self.fileURL = fileURL
        load()
    }

    /// Checks a rule without saving it; throws the reason it would be rejected.
    func validate(wrong rawWrong: String, right rawRight: String) throws -> CorrectionPair {
        let wrong = rawWrong.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = rawRight.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wrong.isEmpty else { throw CorrectionRuleError.emptyWrong }
        guard !right.isEmpty else { throw CorrectionRuleError.emptyRight }
        guard wrong.count >= Self.minimumWrongLength else { throw CorrectionRuleError.wrongTooShort }
        guard wrong != right else { throw CorrectionRuleError.sameAsRight }
        guard !rules.contains(where: { $0.wrong == wrong }) else { throw CorrectionRuleError.duplicateWrong(wrong) }
        return CorrectionPair(wrong: wrong, right: right)
    }

    func add(wrong: String, right: String) throws {
        let pair = try validate(wrong: wrong, right: right)
        try mutate { $0.append(CorrectionRule(wrong: pair.wrong, right: pair.right)) }
    }

    func toggle(_ rule: CorrectionRule) throws {
        try mutate { rules in
            guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
            rules[index].isEnabled.toggle()
        }
    }

    func remove(_ rule: CorrectionRule) throws {
        try mutate { $0.removeAll { $0.id == rule.id } }
    }

    private func mutate(_ body: (inout [CorrectionRule]) -> Void) throws {
        let previous = rules
        body(&rules)
        do { try persist(); writeError = nil }
        catch { rules = previous; writeError = error.localizedDescription; throw error }
    }

    /// An unreadable file leaves the store empty with `loadError` set; transcription then
    /// simply runs without corrections.
    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do { rules = try Self.decoder.decode([CorrectionRule].self, from: Data(contentsOf: fileURL)) }
        catch { rules = []; loadError = error.localizedDescription }
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(rules).write(to: fileURL, options: .atomic)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func defaultFileURL() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("WhisperSwiftUI", isDirectory: true)
            .appendingPathComponent("correction-rules.json")
    }
}
