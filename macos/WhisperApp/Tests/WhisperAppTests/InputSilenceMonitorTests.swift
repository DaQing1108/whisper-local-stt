import Foundation
import Testing
@testable import WhisperApp

struct InputSilenceMonitorTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let quiet = 0.0
    private let loud = 0.3

    private func feed(_ monitor: inout InputSilenceMonitor, seconds: Int, microphone: Double?, system: Double) {
        for second in 0...seconds {
            monitor.record(microphone: microphone, system: system, at: start.addingTimeInterval(Double(second)))
        }
    }

    @Test func nineteenSecondsOfSilenceDoesNotWarnTwentyDoes() {
        var monitor = InputSilenceMonitor()
        feed(&monitor, seconds: 19, microphone: quiet, system: loud)
        #expect(monitor.warnings(at: start.addingTimeInterval(19)).isEmpty)
        monitor.record(microphone: quiet, system: loud, at: start.addingTimeInterval(20))
        #expect(monitor.warnings(at: start.addingTimeInterval(20)) == ["麥克風持續沒有聲音"])
    }

    @Test func warningClearsWhenSoundReturns() {
        var monitor = InputSilenceMonitor()
        feed(&monitor, seconds: 25, microphone: loud, system: quiet)
        #expect(monitor.warnings(at: start.addingTimeInterval(25)) == ["系統音訊持續沒有聲音"])
        monitor.record(microphone: loud, system: loud, at: start.addingTimeInterval(26))
        #expect(monitor.warnings(at: start.addingTimeInterval(26)).isEmpty)
        // 恢復後重新計時
        feed(&monitor, seconds: 10, microphone: loud, system: quiet)
        #expect(monitor.warnings(at: start.addingTimeInterval(10)).isEmpty)
    }

    @Test func microphoneNotJudgedWhenNotEnabled() {
        var monitor = InputSilenceMonitor()
        feed(&monitor, seconds: 30, microphone: nil, system: loud)
        #expect(monitor.warnings(at: start.addingTimeInterval(30)).isEmpty)
        #expect(monitor.microphoneSilentSince == nil)
    }

    @Test func bothSilentWarnsBothAndResetClears() {
        var monitor = InputSilenceMonitor()
        feed(&monitor, seconds: 20, microphone: quiet, system: quiet)
        #expect(monitor.warnings(at: start.addingTimeInterval(20)) == ["麥克風持續沒有聲音", "系統音訊持續沒有聲音"])
        monitor.reset()
        #expect(monitor.warnings(at: start.addingTimeInterval(20)).isEmpty)
    }

    @Test func thresholdMatchesChunkSilenceDetector() {
        #expect(abs(InputSilenceMonitor.silenceLevel - 500.0 / 32_767) < 1e-9)
        var monitor = InputSilenceMonitor()
        feed(&monitor, seconds: 25, microphone: InputSilenceMonitor.silenceLevel, system: loud)  // 等於門檻視為有聲
        #expect(monitor.warnings(at: start.addingTimeInterval(25)).isEmpty)
    }
}
