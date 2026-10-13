import Foundation
import OSLog

enum WorkerLogLevel: String, Sendable {
    case debug, info, error
}

/// One structured Worker lifecycle record. `sessionID` is minted per `WorkerSupervisor.start`
/// and stays constant across automatic restarts of that logical session.
struct WorkerLogEntry: Equatable, Sendable {
    let level: WorkerLogLevel
    let event: String
    let sessionID: UUID
    let requestID: String?
    let jobID: String?
    let detail: String?

    /// Single-line, already-redacted rendering shared by os.Logger and tests.
    var renderedMessage: String {
        var parts = ["event=\(event)", "session=\(sessionID.uuidString)"]
        if let requestID { parts.append("request=\(requestID)") }
        if let jobID { parts.append("job=\(jobID)") }
        if let detail, !detail.isEmpty {
            parts.append("detail=\(WorkerDiagnosticsRedactor.sanitizeDetail(detail))")
        }
        return parts.joined(separator: " ")
    }
}

protocol WorkerLogSink: Sendable {
    func record(_ entry: WorkerLogEntry)
}

enum WorkerDiagnosticsRedactor {
    static let maximumDetailLength = 200
    private static let minimumLiteralLength = 3

    /// Ordered regex rules; secrets first so later path rules never see (or split) them.
    private static let rules: [(pattern: String, template: String)] = [
        (#"sk-[A-Za-z0-9_-]{8,}"#, "<redacted-secret>"),
        (#"hf_[A-Za-z0-9]{8,}"#, "<redacted-secret>"),
        (#"Bearer\s+[A-Za-z0-9._-]+"#, "<redacted-secret>"),
        (#"(?i)(api[_-]?key|token|secret)\s*[:=]\s*\S+"#, "<redacted-secret>"),
        (#"(/(?:private/)?var/folders/[^/\s]+/[^/\s]+/T/)[^\n\r"']+"#, "$1<tmp>"),
        (#"(?i)%2FUsers%2F(?:(?!%2F)[^\s/])+"#, "%2FUsers%2F<redacted>"),
        // Account names may contain spaces/apostrophes: redact up to the next "/".
        (#"(?i)/Users/[^/\n\r"]+"#, "/Users/<redacted>"),
    ]

    /// Hides account names, home paths, temp file names and common secret shapes.
    /// `userName`/`homeDirectory` are the runtime values (injectable for tests); literals
    /// shorter than 3 characters are skipped so they cannot shred unrelated text.
    static func redact(
        _ text: String, userName: String = NSUserName(), homeDirectory: String = NSHomeDirectory()
    ) -> String {
        var result = text
        for rule in rules {
            result = result.replacingOccurrences(
                of: rule.pattern, with: rule.template, options: .regularExpression
            )
        }
        if homeDirectory.count >= minimumLiteralLength {
            result = result.replacingOccurrences(of: homeDirectory, with: "<home>", options: .caseInsensitive)
        }
        if userName.count >= minimumLiteralLength {
            result = result.replacingOccurrences(of: userName, with: "<user>", options: .caseInsensitive)
        }
        return result
    }

    /// Redact first, then truncate, so a cut can never expose part of an unredacted value.
    static func sanitizeDetail(
        _ detail: String, userName: String = NSUserName(), homeDirectory: String = NSHomeDirectory()
    ) -> String {
        let redacted = redact(detail, userName: userName, homeDirectory: homeDirectory)
        guard redacted.count > maximumDetailLength else { return redacted }
        return String(redacted.prefix(maximumDetailLength)) + "…"
    }
}

enum WorkerDiagnosticsFormatting {
    /// Never traps: non-finite or absurdly large counters render as "n/a".
    static func progress(done: Double, total: Double) -> String {
        let limit = 1e15
        guard done.isFinite, total.isFinite, abs(done) < limit, abs(total) < limit else { return "n/a" }
        return "\(Int(done))/\(Int(total))"
    }
}

enum WorkerDiagnosticsLogging {
    static let fallbackSubsystem = "com.via.whisper-swiftui"
    static var subsystem: String { Bundle.main.bundleIdentifier ?? fallbackSubsystem }
}

struct OSLogWorkerSink: WorkerLogSink {
    private let logger = Logger(subsystem: WorkerDiagnosticsLogging.subsystem, category: "WorkerLifecycle")

    func record(_ entry: WorkerLogEntry) {
        let message = entry.renderedMessage
        switch entry.level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
    }
}

/// Collects recent app-subsystem log lines and renders a redacted export file.
struct WorkerDiagnosticsExporter {
    /// Returns raw log lines (oldest first). Injectable so tests never read the system log.
    var lineProvider: () throws -> [String] = Self.systemLogLines

    static func systemLogLines() throws -> [String] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let position = store.position(date: Date().addingTimeInterval(-3600))
        let predicate = NSPredicate(format: "subsystem == %@", WorkerDiagnosticsLogging.subsystem)
        return try store.getEntries(at: position, matching: predicate).compactMap { entry in
            guard let log = entry as? OSLogEntryLog else { return nil }
            return "\(log.date.ISO8601Format()) [\(log.category)] \(log.composedMessage)"
        }
    }

    static let stderrTailLimit = 4000
    static let exportFilePrefix = "WhisperWorkerDiagnostics-"
    static let retainedExports = 5

    func render(stderrTail: String) -> String {
        let lines: [String]
        do { lines = try lineProvider() } catch { lines = ["(system log unavailable: \(error.localizedDescription))"] }
        var sections = ["# Whisper Worker diagnostics", "subsystem: \(WorkerDiagnosticsLogging.subsystem)", "", "## Structured log"]
        sections.append(contentsOf: lines)
        let tail = String(WorkerDiagnosticsRedactor.redact(stderrTail).suffix(Self.stderrTailLimit))
        if !tail.isEmpty {
            sections.append(contentsOf: ["", "## Worker stderr tail (fallback)", tail])
        }
        return WorkerDiagnosticsRedactor.redact(sections.joined(separator: "\n")) + "\n"
    }

    func export(stderrTail: String, directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let stamp = Date().formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
            .replacingOccurrences(of: ":", with: "-")
        let suffix = UUID().uuidString.prefix(8)
        let url = directory.appendingPathComponent("\(Self.exportFilePrefix)\(stamp)-\(suffix).log")
        guard FileManager.default.createFile(
            atPath: url.path, contents: Data(render(stderrTail: stderrTail).utf8),
            attributes: [.posixPermissions: 0o600]
        ) else { throw CocoaError(.fileWriteUnknown) }
        pruneOldExports(in: directory, keeping: url)
        return url
    }

    private func pruneOldExports(in directory: URL, keeping current: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let older = names
            .filter { $0.hasPrefix(Self.exportFilePrefix) && $0.hasSuffix(".log") && $0 != current.lastPathComponent }
            .sorted()
        for stale in older.dropLast(Self.retainedExports - 1) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(stale))
        }
    }
}

/// Temporary instrumentation for "mixed-mode settings not applied" (category MixedSettings).
/// Logs only model/language/domain and the *length* of extra terms, never their content.
enum MixedSettingsDiagnostics {
    private static let logger = Logger(subsystem: WorkerDiagnosticsLogging.subsystem, category: "MixedSettings")

    /// Last 8 hex digits of the object's identity, to tell instances apart in the log.
    static func identity(_ object: AnyObject) -> String {
        String(String(UInt(bitPattern: ObjectIdentifier(object).hashValue), radix: 16).suffix(8))
    }

    static func describe(model: String, language: String?, domain: String, extraTerms: String) -> String {
        "model=\(model) language=\(language ?? "auto") domain=\(domain) extra_chars=\(extraTerms.count)"
    }

    /// `.notice` (default level) so entries persist for `log show` without `--info`.
    static func log(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }
}
