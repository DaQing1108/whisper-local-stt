import Foundation

enum ObsidianExportError: Error, Equatable {
    case invalidVault
    case vaultNotWritable
    case outputEscapedVault
}

struct ObsidianExportService: Sendable {
    private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    func validateVault(_ url: URL) throws -> URL {
        let selected = url.standardizedFileURL
        let values = try? selected.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true else {
            throw ObsidianExportError.invalidVault
        }
        let vault = selected.resolvingSymlinksInPath().standardizedFileURL
        guard FileManager.default.isWritableFile(atPath: vault.path) else {
            throw ObsidianExportError.vaultNotWritable
        }
        return vault
    }

    func export(_ entry: TranscriptionHistoryEntry, to vaultURL: URL) throws -> URL {
        try export(entry, summary: nil, to: vaultURL)
    }

    func export(
        _ entry: TranscriptionHistoryEntry, summary: MeetingSummary?, to vaultURL: URL
    ) throws -> URL {
        // Revalidate at the operation boundary; do not trust a path persisted earlier.
        let vault = try validateVault(vaultURL)
        let sourceName = URL(fileURLWithPath: entry.audioPath).deletingPathExtension().lastPathComponent
        let stem = sanitize(sourceName.isEmpty ? "Transcription" : sourceName)
        let prefix = "\(Self.timestamp.string(from: now())) \(stem) \(entry.id.uuidString.prefix(8))"
        var output: URL
        repeat {
            output = vault.appendingPathComponent("\(prefix) \(UUID().uuidString).md").standardizedFileURL
        } while FileManager.default.fileExists(atPath: output.path)
        guard output.deletingLastPathComponent() == vault else {
            throw ObsidianExportError.outputEscapedVault
        }
        try Data(markdown(for: entry, summary: summary).utf8).write(to: output, options: .atomic)
        return output
    }

    private func markdown(for entry: TranscriptionHistoryEntry, summary: MeetingSummary?) -> String {
        let summarySection = summary.map {
            "# \($0.meetingTitle)\n\n## AI 會議摘要\n\n\($0.effectiveText)\n\n## Source Transcript"
        } ?? "# Transcription"
        return """
        ---
        date: "\(ISO8601DateFormatter().string(from: entry.completedAt))"
        language: "\(yaml(entry.language ?? ""))"
        source: whisper-swiftui
        model: "\(yaml(entry.model))"
        audio_path: "\(yaml(entry.audioPath))"
        status: completed
        meeting_id: "\(summary?.meetingID.uuidString ?? "")"
        tags:
          - transcript
        ---

        \(summarySection)

        \(entry.text)
        """
    }

    private func sanitize(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let cleaned = value.unicodeScalars.map { forbidden.contains($0) ? "-" : String($0) }.joined()
        let collapsed = cleaned.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return String(collapsed.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func yaml(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return formatter
    }()
}
