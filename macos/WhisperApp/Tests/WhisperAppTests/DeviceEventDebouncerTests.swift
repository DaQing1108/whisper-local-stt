import Testing
@testable import WhisperApp
import Foundation

struct DeviceEventDebouncerTests {
    @Test
    func ignoresEventInsideWindow() {
        let now = Date()
        let ignoreUntil = now.addingTimeInterval(1)
        let decision = DeviceEventDebouncer.evaluate(now: now, ignoreUntil: ignoreUntil, interval: 2)
        #expect(decision.shouldIgnore)
        #expect(decision.nextIgnoreUntil == ignoreUntil)
    }

    @Test
    func allowsEventOutsideWindow() {
        let now = Date()
        let ignoreUntil = now.addingTimeInterval(-1)
        let decision = DeviceEventDebouncer.evaluate(now: now, ignoreUntil: ignoreUntil, interval: 2)
        #expect(!decision.shouldIgnore)
    }

    @Test
    func allowsEventWhenNoPriorWindow() {
        let now = Date()
        let decision = DeviceEventDebouncer.evaluate(now: now, ignoreUntil: nil, interval: 2)
        #expect(!decision.shouldIgnore)
    }

    @Test
    func settingNextWindowExtendsIntervalFromNow() {
        let now = Date()
        let decision = DeviceEventDebouncer.evaluate(now: now, ignoreUntil: nil, interval: 2)
        #expect(decision.nextIgnoreUntil == now.addingTimeInterval(2))
    }
}
