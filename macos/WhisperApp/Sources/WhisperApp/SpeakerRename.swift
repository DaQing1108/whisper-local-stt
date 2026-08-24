import Foundation

/// Pure text-transform helpers for renaming speaker labels (e.g. "[Speaker A]")
/// inside a plain-text transcript draft. No SwiftUI/Observation dependency so
/// these are trivially unit-testable.
enum SpeakerRename {
    /// Scans `text` line by line and collects unique "[Label] ..." prefixes, in
    /// order of first appearance. A line qualifies when it starts with `[`,
    /// contains a closing `]`, and that `]` is immediately followed by a space.
    ///
    /// "[MM:SS]" / "[HH:MM:SS]" timecode prefixes (used by non-diarized live and
    /// mixed-recording transcripts — see TranscriptTimecodeFormatter and
    /// ContentView+Results.segmentLabel) are excluded: they share the same
    /// bracket shape but are never speaker labels.
    static func extractSpeakerLabels(from text: String) -> [String] {
        var seen: Set<String> = []
        var labels: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.hasPrefix("["), let closingIndex = line.firstIndex(of: "]") else { continue }
            let afterClosing = line.index(after: closingIndex)
            guard afterClosing < line.endIndex, line[afterClosing] == " " else { continue }
            let label = String(line[line.index(after: line.startIndex)..<closingIndex])
            guard !isTimecodeLabel(label) else { continue }
            guard seen.insert(label).inserted else { continue }
            labels.append(label)
        }
        return labels
    }

    /// True when `label` is a "MM:SS" or "HH:MM:SS" timecode (2–3 groups of
    /// exactly two digits each) rather than a genuine speaker name.
    private static func isTimecodeLabel(_ label: String) -> Bool {
        let parts = label.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return false }
        return parts.allSatisfy { $0.count == 2 && $0.allSatisfy { $0.isASCII && $0.isNumber } }
    }

    /// Replaces each "[oldLabel] " line prefix in `text` with "[newName] " for
    /// every mapping in `renames`. Only whole-prefix matches are replaced, never
    /// substrings inside the transcript body. Names containing `[`/`]` have
    /// those characters stripped before substitution. "[MM:SS]"/"[HH:MM:SS]"
    /// timecode prefixes are never renamed, even if `renames` happens to
    /// contain a timecode-shaped key (see `isTimecodeLabel`).
    static func applySpeakerRenames(_ renames: [String: String], in text: String) -> String {
        guard !renames.isEmpty else { return text }
        let sanitizedRenames = renames.mapValues {
            $0.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let renamedLines = lines.map { line -> String in
            guard line.hasPrefix("["), let closingIndex = line.firstIndex(of: "]") else { return String(line) }
            let afterClosing = line.index(after: closingIndex)
            guard afterClosing < line.endIndex, line[afterClosing] == " " else { return String(line) }
            let label = String(line[line.index(after: line.startIndex)..<closingIndex])
            guard !isTimecodeLabel(label) else { return String(line) }
            guard let newName = sanitizedRenames[label] else { return String(line) }
            let rest = line[afterClosing...]
            return "[\(newName)]\(rest)"
        }
        return renamedLines.joined(separator: "\n")
    }
}
