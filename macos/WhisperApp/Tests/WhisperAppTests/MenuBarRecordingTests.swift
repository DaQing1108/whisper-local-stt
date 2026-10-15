import AppKit
import Foundation
import Testing
@testable import WhisperApp

struct MenuBarRulesTests {
    // AC-A1: three modes × idle / recording / finishing.
    @Test func phaseMappingPerMode() {
        let saved = RecordingState.recorded(URL(fileURLWithPath: "/tmp/a.wav"))
        #expect(CapturePhase.standard(.idle, transcriptionInFlight: false) == .idle)
        #expect(CapturePhase.standard(.requestingPermission, transcriptionInFlight: false) == .idle)
        #expect(CapturePhase.standard(.ready, transcriptionInFlight: false) == .idle)
        #expect(CapturePhase.standard(.recording(startedAt: Date()), transcriptionInFlight: false) == .recording)
        #expect(CapturePhase.standard(.finalizing, transcriptionInFlight: false) == .finishing)
        #expect(CapturePhase.standard(saved, transcriptionInFlight: true) == .finishing)    // 停止後轉錄中
        #expect(CapturePhase.standard(saved, transcriptionInFlight: false) == .idle)
        #expect(CapturePhase.standard(.failed("x"), transcriptionInFlight: false) == .idle)
        #expect(CapturePhase.live(.idle) == .idle)
        #expect(CapturePhase.live(.requestingPermission) == .idle)
        #expect(CapturePhase.live(.recording) == .recording)
        #expect(CapturePhase.live(.recovering) == .recording)
        #expect(CapturePhase.live(.stopping) == .finishing)
        #expect(CapturePhase.live(.draining) == .finishing)
        #expect(CapturePhase.live(.failed("x")) == .idle)
        #expect(CapturePhase.mixed(.idle, isDraining: false) == .idle)
        #expect(CapturePhase.mixed(.recording, isDraining: false) == .recording)
        #expect(CapturePhase.mixed(.stopping, isDraining: false) == .finishing)
        #expect(CapturePhase.mixed(.idle, isDraining: true) == .finishing)
        #expect(CapturePhase.mixed(.failed("x"), isDraining: false) == .idle)
    }

    @Test func visibilityLabelAndButtons() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(!MenuBarRules.isShown(.idle))
        #expect(MenuBarRules.isShown(.recording) && MenuBarRules.isShown(.finishing))
        #expect(MenuBarRules.label(phase: .recording, startedAt: start, now: start.addingTimeInterval(5)) == "0:00:05")
        #expect(MenuBarRules.label(phase: .finishing, startedAt: start, now: start) == "轉錄中…")
        #expect(MenuBarRules.label(phase: .idle, startedAt: nil, now: start).isEmpty)
        #expect(MenuBarRules.stopButtonTitle(mode: .standard) == "停止並轉錄")
        #expect(MenuBarRules.stopButtonTitle(mode: .mixed) == "停止並轉錄")
        #expect(MenuBarRules.stopButtonTitle(mode: .live) == "停止即時模式")
        #expect(MenuBarRules.stopEnabled(phase: .recording, canStop: true, stopRequested: false))
        #expect(!MenuBarRules.stopEnabled(phase: .recording, canStop: true, stopRequested: true))   // 防連點
        #expect(!MenuBarRules.stopEnabled(phase: .recording, canStop: false, stopRequested: false)) // 主視窗停止也停用時
        #expect(!MenuBarRules.stopEnabled(phase: .finishing, canStop: true, stopRequested: false))
    }

    // AC-A3
    @Test func elapsedText() {
        let start = Date(timeIntervalSince1970: 0)
        #expect(MenuBarRules.elapsedText(from: start, to: start.addingTimeInterval(5)) == "0:00:05")
        #expect(MenuBarRules.elapsedText(from: start, to: start.addingTimeInterval(6_773)) == "1:52:53")
        #expect(MenuBarRules.elapsedText(from: start, to: start.addingTimeInterval(-3)) == "0:00:00")
    }

    // AC-A2
    @Test func recentTranscriptLines() {
        let transcript = """
        [00:00:01] 第一行
        [00:00:05] 第二行

        [01:02:03] 第三行
        [12:34] 第四行沒有小時
        """
        #expect(MenuBarRules.recentLines(transcript) == ["第二行", "第三行", "第四行沒有小時"])
        #expect(MenuBarRules.recentLines("") == [])
        #expect(MenuBarRules.recentLines("\n \n") == [])
        let long = String(repeating: "長", count: 70)
        #expect(MenuBarRules.recentLines("[00:00:01] \(long)") == [String(repeating: "長", count: 60) + "…"])
        #expect(MenuBarRules.recentLines("沒有時間碼的一行") == ["沒有時間碼的一行"])
    }

    // AC-B1, AC-B3
    @Test func closeAndQuitRules() {
        #expect(MainWindowRules.closeAction(phase: .recording) == .hide)
        #expect(MainWindowRules.closeAction(phase: .finishing) == .hide)
        #expect(MainWindowRules.closeAction(phase: .idle) == .close)
        #expect(MainWindowRules.quitNeedsConfirmation(phase: .recording))
        #expect(MainWindowRules.quitNeedsConfirmation(phase: .finishing))
        #expect(!MainWindowRules.quitNeedsConfirmation(phase: .idle))
    }
}

@MainActor
struct CaptureStatusBoardTests {
    private func snapshot(_ phase: CapturePhase, startedAt: Date? = nil) -> CaptureSnapshot {
        CaptureSnapshot(mode: .mixed, phase: phase, startedAt: startedAt, canStop: phase == .recording,
                        statusText: nil, silenceWarnings: [])
    }

    // AC-A5 (board side): written on start, kept through finishing, cleared on idle.
    @Test func lifecycleKeepsStartThroughFinishingAndClearsOnIdle() {
        let board = CaptureStatusBoard()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        board.update(snapshot(.recording, startedAt: start))
        #expect(board.snapshot.startedAt == start)
        board.update(snapshot(.finishing))                 // ContentView clears captureStartedAt on stop
        #expect(board.snapshot.phase == .finishing)
        #expect(board.snapshot.startedAt == start)
        board.update(snapshot(.idle))
        #expect(board.snapshot.phase == .idle)
        #expect(board.snapshot.startedAt == nil)
    }

    // AC-A4: menu-bar stop posts the same notification the main window's command posts, once.
    @Test func stopRequestUsesToggleRecordingNotificationOnce() async {
        let board = CaptureStatusBoard()
        board.update(snapshot(.recording, startedAt: Date()))
        let counter = NotificationCounter(name: .whisperToggleRecording)

        board.requestStop()
        board.requestStop()                                 // 連點
        #expect(counter.count == 1)
        #expect(board.stopRequested)

        board.update(snapshot(.finishing))
        #expect(!board.stopRequested)
        board.requestStop()                                 // finishing：不再送出
        #expect(counter.count == 1)

        var notStoppable = snapshot(.recording, startedAt: Date())
        notStoppable.canStop = false                        // ContentView 會忽略 toggle 的狀態
        board.update(notStoppable)
        board.requestStop()
        #expect(counter.count == 1)
        #expect(!board.stopRequested)                       // 不會卡住
        board.update(snapshot(.idle))                       // stop the 1s ticker
    }
}

/// No real NSWindow here: creating one connects to the window server on the main thread and
/// starves timing-sensitive tests running in parallel. The close/hide decision is covered by
/// `closeAndQuitRules`; the AppKit wiring (orderOut / makeKeyAndOrderFront) is verified on device.
@MainActor
struct MainWindowCloseGuardTests {
    private final class OriginalDelegate: NSObject, NSWindowDelegate {
        var resizeCalls = 0
        func windowDidResize(_ notification: Notification) { resizeCalls += 1 }
    }

    @Test func nonCloseDelegateCallsAreForwardedToOriginalDelegate() {
        let original = OriginalDelegate()
        let windowGuard = MainWindowCloseGuard()
        windowGuard.adopt(originalDelegate: original)

        #expect(windowGuard.responds(to: #selector(NSWindowDelegate.windowDidResize(_:))))
        #expect(windowGuard.responds(to: #selector(NSWindowDelegate.windowShouldClose(_:))))
        #expect(!windowGuard.responds(to: #selector(NSWindowDelegate.windowWillMiniaturize(_:))))
        windowGuard.perform(#selector(NSWindowDelegate.windowDidResize(_:)),
                            with: Notification(name: NSWindow.didResizeNotification))
        #expect(original.resizeCalls == 1)
        #expect(!windowGuard.hasHiddenWindow)               // nothing hidden, no window attached
    }
}

private final class NotificationCounter {
    private(set) var count = 0
    private var token: NSObjectProtocol?
    init(name: Notification.Name) {
        token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
            self?.count += 1
        }
    }
    deinit { if let token { NotificationCenter.default.removeObserver(token) } }
}
