import Foundation
import Observation

/// What ContentView's capture flows are doing, shared with the menu-bar indicator.
/// ContentView writes a snapshot derived from its existing state whenever that state changes
/// (so failure paths clear it too); the menu bar only reads it and asks to stop through the
/// same `.whisperToggleRecording` entry point as the main window.
struct CaptureSnapshot: Equatable, Sendable {
    var mode: AudioInputMode
    var phase: CapturePhase
    var startedAt: Date?
    /// Same condition as the main window's stop button (`isPrimaryRecording && primaryActionEnabled`).
    var canStop: Bool = false
    var statusText: String?
    var silenceWarnings: [String]

    static let idle = CaptureSnapshot(mode: .standard, phase: .idle, startedAt: nil, statusText: nil, silenceWarnings: [])
}

@MainActor
@Observable
final class CaptureStatusBoard {
    private(set) var snapshot = CaptureSnapshot.idle
    /// Ticks once a second while a capture is active, so menu-bar text re-renders.
    private(set) var now = Date()
    /// Set by the menu-bar stop button; cleared when the phase moves on, preventing double stops.
    private(set) var stopRequested = false
    /// Keeps the main window (and the flows inside ContentView) alive while capturing.
    @ObservationIgnored let windowGuard = MainWindowCloseGuard()
    @ObservationIgnored private var ticker: Timer?

    init() {
        windowGuard.currentPhase = { [weak self] in self?.snapshot.phase ?? .idle }
    }

    func update(_ newSnapshot: CaptureSnapshot) {
        guard newSnapshot != snapshot else { return }
        if newSnapshot.phase != snapshot.phase { stopRequested = false }
        // Keep the start time through finishing (ContentView clears its own on stop).
        var merged = newSnapshot
        if merged.phase == .finishing, merged.startedAt == nil { merged.startedAt = snapshot.startedAt }
        if merged.phase == .idle { merged.startedAt = nil }
        snapshot = merged
        now = Date()
        merged.phase.isActive ? startTicking() : stopTicking()
    }

    /// Menu-bar stop: the same notification the main window's menu command posts.
    func requestStop() {
        guard MenuBarRules.stopEnabled(
            phase: snapshot.phase, canStop: snapshot.canStop, stopRequested: stopRequested
        ) else { return }
        stopRequested = true
        NotificationCenter.default.post(name: .whisperToggleRecording, object: nil)
    }

    private func startTicking() {
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }
}
