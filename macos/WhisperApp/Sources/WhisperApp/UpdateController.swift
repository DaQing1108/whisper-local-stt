import Foundation
import Observation
#if canImport(Sparkle)
import Sparkle
#endif

@MainActor
protocol ApplicationUpdateChecking: AnyObject {
    var canCheckForUpdates: Bool { get }
    func checkForUpdates()
}

enum ReleaseUpdateConfiguration: Equatable, Sendable {
    case valid
    case invalid(String)

    static func read(from bundle: Bundle) -> ReleaseUpdateConfiguration {
        guard let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: feed), url.scheme == "https" else {
            return .invalid("Signed HTTPS appcast is not configured")
        }
        guard let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .invalid("Sparkle EdDSA public key is not configured")
        }
        return .valid
    }
}

#if canImport(Sparkle)
@MainActor
private final class SparkleUpdateChecker: ApplicationUpdateChecking {
    private let controller = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }
    func checkForUpdates() { controller.checkForUpdates(nil) }
}
#endif

@MainActor
private final class DisabledUpdateChecker: ApplicationUpdateChecking {
    var canCheckForUpdates: Bool { false }
    func checkForUpdates() {}
}

@MainActor
@Observable
final class UpdateController {
    private let checker: any ApplicationUpdateChecking
    private let configuration: ReleaseUpdateConfiguration
    private(set) var statusMessage: String

    var canCheckForUpdates: Bool {
        configuration == .valid && checker.canCheckForUpdates
    }

    init(checker: any ApplicationUpdateChecking, configuration: ReleaseUpdateConfiguration) {
        self.checker = checker
        self.configuration = configuration
        switch configuration {
        case .valid: statusMessage = "Update service ready"
        case .invalid(let reason): statusMessage = reason
        }
    }

    static func production(bundle: Bundle = .main) -> UpdateController {
        var configuration = ReleaseUpdateConfiguration.read(from: bundle)
        let checker: any ApplicationUpdateChecking
#if canImport(Sparkle)
        checker = configuration == .valid ? SparkleUpdateChecker() : DisabledUpdateChecker()
#else
        if configuration == .valid {
            configuration = .invalid("Sparkle framework is unavailable in this build")
        }
        checker = DisabledUpdateChecker()
#endif
        return UpdateController(checker: checker, configuration: configuration)
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        statusMessage = "Checking for updates…"
        checker.checkForUpdates()
    }
}
