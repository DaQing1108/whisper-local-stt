import Testing
import SwiftUI
@testable import WhisperApp

struct MeetingSummaryStatusDaylightColorTests {
    @Test
    func completedStatusUsesTheActiveAccent() {
        #expect(MeetingSummaryStatus.completed.daylightColor == DaylightPalette.accentActive)
    }

    @Test
    func failedStatusUsesTheRecordAccent() {
        #expect(MeetingSummaryStatus.failed.daylightColor == DaylightPalette.accentRecord)
    }

    @Test
    func generatingStatusUsesTheNeutralColor() {
        #expect(MeetingSummaryStatus.generating.daylightColor == Color.secondary)
    }

    @Test
    func emptyStatusUsesTheNeutralColor() {
        #expect(MeetingSummaryStatus.empty.daylightColor == Color.secondary)
    }
}
