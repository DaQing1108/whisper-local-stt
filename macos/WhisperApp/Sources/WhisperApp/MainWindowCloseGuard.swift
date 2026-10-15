import AppKit
import SwiftUI

/// While a capture is active, closing the main window (close button / ⌘W) only hides it, so
/// ContentView — which owns chunk accumulation and stop-and-save — keeps running.
///
/// Mechanism: wraps the window's existing (SwiftUI-installed) delegate. `windowShouldClose` is
/// answered here; every other delegate call is forwarded to the original delegate unchanged.
/// When no capture is active the original delegate decides, i.e. closing behaves as before.
@MainActor
final class MainWindowCloseGuard: NSObject, NSWindowDelegate {
    private(set) weak var window: NSWindow?
    /// Strong: NSWindow.delegate is weak and the guard replaces it.
    private var originalDelegate: NSWindowDelegate?
    var currentPhase: () -> CapturePhase = { .idle }
    /// Only a window this guard hid is revived; a window the user really closed is left alone.
    private(set) var isHiddenForCapture = false

    func attach(to window: NSWindow) {
        // A second window (⌘N) must not take over while the guarded one still exists.
        if let current = self.window, current !== window, current.isVisible || isHiddenForCapture { return }
        self.window = window
        guard window.delegate !== self else { return }
        adopt(originalDelegate: window.delegate)
        window.delegate = self
    }

    /// The delegate every call except `windowShouldClose` (while capturing) is forwarded to.
    func adopt(originalDelegate: NSWindowDelegate?) {
        self.originalDelegate = originalDelegate
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        switch MainWindowRules.closeAction(phase: currentPhase()) {
        case .hide:
            sender.orderOut(nil)
            isHiddenForCapture = true
            return false
        case .close:
            return originalDelegate?.windowShouldClose?(sender) ?? true
        }
    }

    /// True when the guarded window was hidden by a close during a capture and still exists.
    var hasHiddenWindow: Bool { isHiddenForCapture && window != nil }

    /// 「打開 Whisper」/ Dock click: bring back the same window, never a new ContentView.
    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        isHiddenForCapture = false
    }

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (originalDelegate?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let originalDelegate, originalDelegate.responds(to: aSelector), !super.responds(to: aSelector) {
            return originalDelegate
        }
        return super.forwardingTarget(for: aSelector)
    }
}

/// Hands the hosting NSWindow to the guard (and re-attaches if SwiftUI swaps the delegate).
struct MainWindowAccessor: NSViewRepresentable {
    let windowGuard: MainWindowCloseGuard

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window { windowGuard.attach(to: window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window { windowGuard.attach(to: window) }
    }
}

/// ⌘Q confirmation and Dock-click reopen while a capture is active.
@MainActor
final class WhisperAppDelegate: NSObject, NSApplicationDelegate {
    static weak var board: CaptureStatusBoard?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let board = Self.board, MainWindowRules.quitNeedsConfirmation(phase: board.snapshot.phase),
              !Self.isSystemInitiatedQuit else {
            return .terminateNow
        }
        let alert = NSAlert()
        alert.messageText = MainWindowRules.quitConfirmationMessage
        alert.alertStyle = .warning
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "結束")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    /// Logout / restart / shutdown carry a quit reason; a modal prompt there would block the system.
    private static var isSystemInitiatedQuit: Bool {
        NSAppleEventManager.shared().currentAppleEvent?.attributeDescriptor(forKeyword: kAEQuitReason) != nil
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag, let windowGuard = Self.board?.windowGuard, windowGuard.hasHiddenWindow else { return true }
        windowGuard.showMainWindow()
        return false
    }
}
