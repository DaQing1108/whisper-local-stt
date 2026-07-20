import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum TranscriptionExportError: Error, Equatable {
    case missingSegments
}

enum TranscriptionExportFormat: String, CaseIterable, Identifiable {
    case text = "TXT"
    case timecodedText = "Timecoded TXT"
    case markdown = "Markdown"
    case srt = "SRT"

    var id: Self { self }
    var filenameExtension: String {
        switch self {
        case .markdown: "md"
        case .text, .timecodedText: "txt"
        case .srt: "srt"
        }
    }

    func render(entry: TranscriptionHistoryEntry, editedText: String) throws -> String {
        switch self {
        case .text:
            return editedText
        case .timecodedText:
            return TranscriptTimecodeFormatter.render(
                segments: entry.segments,
                fallbackText: editedText
            )
        case .markdown:
            let name = URL(fileURLWithPath: entry.audioPath).lastPathComponent
            return "# \(name)\n\n\(editedText)\n"
        case .srt:
            guard !entry.segments.isEmpty else { throw TranscriptionExportError.missingSegments }
            return entry.segments.enumerated().map { index, segment in
                "\(index + 1)\n\(Self.timestamp(segment.start)) --> \(Self.timestamp(segment.end))\n\(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))"
            }.joined(separator: "\n\n") + "\n"
        }
    }

    private static func timestamp(_ seconds: Double) -> String {
        let milliseconds = max(0, Int((seconds * 1_000).rounded()))
        return String(
            format: "%02d:%02d:%02d,%03d",
            milliseconds / 3_600_000,
            (milliseconds / 60_000) % 60,
            (milliseconds / 1_000) % 60,
            milliseconds % 1_000
        )
    }
}

enum TranscriptTimecodeFormatter {
    static func render(
        segments: [TranscriptionSegment], fallbackText: String = "", fallbackStart: Double = 0
    ) -> String {
        if segments.isEmpty {
            let text = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "" : "[\(timestamp(fallbackStart))] \(text)"
        }
        return segments.map { segment in
            "[\(timestamp(segment.start))] \(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))"
        }.joined(separator: "\n")
    }

    private static func timestamp(_ seconds: Double) -> String {
        let wholeSeconds = max(0, Int(seconds.rounded(.down)))
        return String(
            format: "%02d:%02d:%02d",
            wholeSeconds / 3_600,
            (wholeSeconds / 60) % 60,
            wholeSeconds % 60
        )
    }
}

struct TranscriptionExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText]
    let content: String

    init(content: String) { self.content = content }
    init(configuration: ReadConfiguration) throws {
        content = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(content.utf8))
    }
}
