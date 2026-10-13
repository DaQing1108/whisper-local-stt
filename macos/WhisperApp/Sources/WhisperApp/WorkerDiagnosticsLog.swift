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
            parts.append("detail=\(WorkerDiagnosticsRedactor.redact(detail))")
        }
        return parts.joined(separator: " ")
    }
}

protocol WorkerLogSink: Sendable {
    func record(_ entry: WorkerLogEntry)
}

enum WorkerDiagnosticsRedactor {
    /// Hides the macOS account name in any `/Users/<name>` path fragment.
    static func redact(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"/Users/[^/\s"'\\]+"#, with: "/Users/<redacted>", options: .regularExpression
        )
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

    func render(stderrTail: String) -> String {
        let lines: [String]
        do { lines = try lineProvider() } catch { lines = ["(system log unavailable: \(error.localizedDescription))"] }
        var sections = ["# Whisper Worker diagnostics", "subsystem: \(WorkerDiagnosticsLogging.subsystem)", "", "## Structured log"]
        sections.append(contentsOf: lines)
        if !stderrTail.isEmpty {
            sections.append(contentsOf: ["", "## Worker stderr tail (fallback)", stderrTail])
        }
        return WorkerDiagnosticsRedactor.redact(sections.joined(separator: "\n")) + "\n"
    }

    func export(stderrTail: String, directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let stamp = Date().ISO8601Format().replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent("WhisperWorkerDiagnostics-\(stamp).log")
        try Data(render(stderrTail: stderrTail).utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }
}
