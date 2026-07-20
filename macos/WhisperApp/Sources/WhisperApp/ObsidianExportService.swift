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
        try export(entry, summary: nil, existingPath: nil, to: vaultURL)
    }

    func export(
        _ entry: TranscriptionHistoryEntry, summary: MeetingSummary?, to vaultURL: URL
    ) throws -> URL {
        try export(entry, summary: summary, existingPath: nil, to: vaultURL)
    }

    /// Republishing the same entry updates `existingPath` in place instead of creating a new
    /// note, mirroring integrations.py's save_to_obsidian: only checks the path still resolves
    /// inside the vault, not whether the file currently exists — write-or-overwrite either way.
    func export(
        _ entry: TranscriptionHistoryEntry, summary: MeetingSummary?, existingPath: URL?, to vaultURL: URL
    ) throws -> URL {
        // Revalidate at the operation boundary; do not trust a path persisted earlier.
        let vault = try validateVault(vaultURL)
        let output: URL
        if let existingPath, isWithinVault(existingPath, vault: vault) {
            output = existingPath
        } else {
            let sourceName = URL(fileURLWithPath: entry.audioPath).deletingPathExtension().lastPathComponent
            let stem = sanitize(sourceName.isEmpty ? "Transcription" : sourceName)
            let prefix = "\(Self.timestamp.string(from: now())) \(stem) \(entry.id.uuidString.prefix(8))"
            var candidate: URL
            repeat {
                candidate = vault.appendingPathComponent("\(prefix) \(UUID().uuidString).md").standardizedFileURL
            } while FileManager.default.fileExists(atPath: candidate.path)
            guard candidate.deletingLastPathComponent() == vault else {
                throw ObsidianExportError.outputEscapedVault
            }
            output = candidate
        }
        try Data(markdown(for: entry, summary: summary).utf8).write(to: output, options: .atomic)
        return output
    }

    /// Any depth under the vault counts, matching integrations.py's Path.relative_to check —
    /// a note the user has organized into a vault subfolder must still be recognized on republish.
    private func isWithinVault(_ url: URL, vault: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        let vaultPrefix = vault.path.hasSuffix("/") ? vault.path : vault.path + "/"
        return resolved.hasPrefix(vaultPrefix)
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

        \(transcriptBody(for: entry))
        """
    }

    /// Matches integrations.py's save_to_obsidian exactly: bracketed [MM:SS] lines (not
    /// [HH:MM:SS] — that format belongs to TranscriptionExportService's separate "Timecoded
    /// TXT" export) only when segments exist, otherwise plain text with no timestamp prefix.
    private func transcriptBody(for entry: TranscriptionHistoryEntry) -> String {
        guard !entry.segments.isEmpty else { return entry.text }
        return entry.segments.map { segment in
            let wholeSeconds = max(0, Int(segment.start.rounded(.down)))
            let timestamp = String(format: "%02d:%02d", wholeSeconds / 60, wholeSeconds % 60)
            return "[\(timestamp)] \(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))"
        }.joined(separator: "\n")
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
