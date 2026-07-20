import AppKit
@preconcurrency import AVFoundation
import Foundation

enum AudioCaptureSystemEvent: Equatable, Sendable {
    case configurationChanged
    case deviceChanged
    case interruptionBegan
    case interruptionEnded
}

@MainActor
protocol AudioCaptureEventMonitoring: AnyObject {
    func start(handler: @escaping @MainActor @Sendable (AudioCaptureSystemEvent) -> Void)
    func stop()
}

@MainActor
final class SystemAudioCaptureEventMonitor: AudioCaptureEventMonitoring {
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var generation = 0

    func start(handler: @escaping @MainActor @Sendable (AudioCaptureSystemEvent) -> Void) {
        stop()
        generation &+= 1
        let activeGeneration = generation
        observe(NotificationCenter.default, name: .AVAudioEngineConfigurationChange, generation: activeGeneration) {
            handler(.configurationChanged)
        }
        observe(NotificationCenter.default, name: Notification.Name("AVCaptureDeviceWasConnectedNotification"), generation: activeGeneration) {
            handler(.deviceChanged)
        }
        observe(NotificationCenter.default, name: Notification.Name("AVCaptureDeviceWasDisconnectedNotification"), generation: activeGeneration) {
            handler(.deviceChanged)
        }
        observe(NSWorkspace.shared.notificationCenter, name: NSWorkspace.willSleepNotification, generation: activeGeneration, synchronously: true) {
            handler(.interruptionBegan)
        }
        observe(NSWorkspace.shared.notificationCenter, name: NSWorkspace.didWakeNotification, generation: activeGeneration) {
            handler(.interruptionEnded)
        }
    }

    func stop() {
        generation &+= 1
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
    }

    private func observe(
        _ center: NotificationCenter,
        name: Notification.Name,
        generation: Int,
        synchronously: Bool = false,
        action: @escaping @MainActor @Sendable () -> Void
    ) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            if synchronously {
                MainActor.assumeIsolated {
                    guard self?.generation == generation else { return }
                    action()
                }
                return
            }
            Task { @MainActor [weak self] in
                guard self?.generation == generation else { return }
                action()
            }
        }
        observers.append((center, observer))
    }
}

struct RecordingArtifactCleaner {
    /// Removes only header-only WAV artifacts that are not protected by an active/nonterminal job.
    func removeEmptyOrphans(in directory: URL, protectedURLs: Set<URL>) throws -> [URL] {
        let protectedPaths = Set(protectedURLs.map { $0.resolvingSymlinksInPath().path })
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var removed: [URL] = []
        for file in files where file.pathExtension.lowercased() == "wav"
            && !protectedPaths.contains(file.resolvingSymlinksInPath().path) {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let data = try Data(contentsOf: file)
            guard data.count == 44,
                  data[0..<4] == Data("RIFF".utf8),
                  data[8..<12] == Data("WAVE".utf8),
                  data[12..<16] == Data("fmt ".utf8),
                  data[36..<40] == Data("data".utf8),
                  data[40..<44] == Data([0, 0, 0, 0]) else { continue }
            try FileManager.default.removeItem(at: file)
            removed.append(file)
        }
        return removed
    }
}
