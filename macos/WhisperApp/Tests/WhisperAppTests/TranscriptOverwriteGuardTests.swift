import Testing
@testable import WhisperApp

struct TranscriptOverwriteGuardTests {
    private func text(_ count: Int) -> String { String(repeating: "字", count: count) }

    @Test("273-char transcript replaced by 89 chars is a destructive shrink")
    func realCaseShrinkIsFlagged() {
        #expect(
            TranscriptOverwriteGuard.isDestructiveShrink(
                existingText: text(273), incomingText: text(89)
            )
        )
    }

    @Test("Minor 5000 -> 4800 change is not destructive")
    func minorChangeIsNotFlagged() {
        #expect(
            !TranscriptOverwriteGuard.isDestructiveShrink(
                existingText: text(5000), incomingText: text(4800)
            )
        )
    }

    @Test("Existing shorter than the 200-char floor is never guarded")
    func smallEntriesAreNotGuarded() {
        #expect(
            !TranscriptOverwriteGuard.isDestructiveShrink(
                existingText: text(120), incomingText: text(5)
            )
        )
    }

    @Test("Incoming exactly at 50% is not destructive (strict less-than)")
    func exactlyAtThresholdIsNotFlagged() {
        #expect(
            !TranscriptOverwriteGuard.isDestructiveShrink(
                existingText: text(1000), incomingText: text(500)
            )
        )
    }

    @Test("Incoming one char below 50% is destructive")
    func justBelowThresholdIsFlagged() {
        #expect(
            TranscriptOverwriteGuard.isDestructiveShrink(
                existingText: text(1000), incomingText: text(499)
            )
        )
    }

    @Test("Empty existing and empty incoming does not crash and is not destructive")
    func emptyInputsAreSafe() {
        #expect(
            !TranscriptOverwriteGuard.isDestructiveShrink(existingText: "", incomingText: "")
        )
    }
}
