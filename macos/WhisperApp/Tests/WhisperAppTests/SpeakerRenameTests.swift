import Testing
@testable import WhisperApp

struct SpeakerRenameTests {
    @Test
    func extractsUniqueLabelsInFirstAppearanceOrder() {
        let text = "[Speaker A] hi\n[Speaker B] yo\n[Speaker A] again"
        #expect(SpeakerRename.extractSpeakerLabels(from: text) == ["Speaker A", "Speaker B"])
    }

    @Test
    func appliesRenameToMatchingLabelAndLeavesOthersUntouched() {
        let text = "[Speaker A] hi\n[Speaker B] yo"
        let result = SpeakerRename.applySpeakerRenames(["Speaker A": "Alex"], in: text)
        #expect(result == "[Alex] hi\n[Speaker B] yo")
    }

    @Test
    func extractReturnsEmptyForTextWithoutSpeakerLabels() {
        #expect(SpeakerRename.extractSpeakerLabels(from: "just a plain paragraph, no labels here.") == [])
    }

    @Test
    func applyReturnsInputUnchangedWhenNoRenamesOrNoMatch() {
        let text = "[Speaker A] hi"
        #expect(SpeakerRename.applySpeakerRenames([:], in: text) == text)
        #expect(SpeakerRename.applySpeakerRenames(["Speaker Z": "Nobody"], in: text) == text)
    }

    @Test
    func newNameContainingBracketsIsSanitizedAndDoesNotCrash() {
        let text = "[Speaker A] hi"
        let result = SpeakerRename.applySpeakerRenames(["Speaker A": "Al[ex]"], in: text)
        #expect(result == "[Alex] hi")
        let bracketCount = result.filter { $0 == "[" || $0 == "]" }.count
        #expect(bracketCount == 2)
    }

    @Test
    func extractIgnoresMMSSTimecodePrefixedLines() {
        // Non-diarized live/mixed-recording transcripts are rendered with
        // "[MM:SS] text" timecode prefixes (TranscriptTimecodeFormatter / segmentLabel).
        // These must never be mistaken for speaker labels.
        let text = "[00:05] hi\n[00:07] there"
        #expect(SpeakerRename.extractSpeakerLabels(from: text) == [])
    }

    @Test
    func extractIgnoresHHMMSSTimecodePrefixedLines() {
        // TranscriptTimecodeFormatter.render uses "[HH:MM:SS] text" for live/mixed recordings.
        let text = "[00:04:32] 當然就可以了\n[00:04:33] 接下來還還要"
        #expect(SpeakerRename.extractSpeakerLabels(from: text) == [])
    }

    @Test
    func extractStillFindsRealSpeakerLabelsMixedWithTimecodeLines() {
        // Guards against an overcorrection that would ignore genuine speaker
        // labels just because timecode lines are also present.
        let text = "[Speaker A] hi\n[00:07] not a speaker\n[Speaker B] yo"
        #expect(SpeakerRename.extractSpeakerLabels(from: text) == ["Speaker A", "Speaker B"])
    }

    @Test
    func applyDoesNotRenameTimecodePrefixedLinesEvenIfKeyProvided() {
        // Defense in depth: applySpeakerRenames must not clobber a "[MM:SS]"
        // timecode even if a caller accidentally passes a timecode-shaped key.
        let text = "[00:07] hi"
        let result = SpeakerRename.applySpeakerRenames(["00:07": "Alex"], in: text)
        #expect(result == text)
    }
}
