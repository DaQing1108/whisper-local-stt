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
}
